# Adapted from https://jump.dev/2023/07/20/gams-blog/
using CSV
using DataFrames
using DuckDB
using HiGHS
using JSON
using JuMP
using LaTeXStrings
using Plots
using Printf
using Statistics
using TimerOutputs
gr()

const data_dir = joinpath(@__DIR__, "IJKLM", "data")

function parsefile_tuple(filename::String)
    return [tuple(x...) for x in JSON.parsefile(filename)]
end
function parsefile_dataframe(filename::String, indices)
    list = parsefile_tuple(filename)
    return DataFrames.DataFrame(
        [index => getindex.(list, i) for (i, index) in enumerate(indices)]...,
    )
end

struct DataFrameData
    I::Vector{String}
    IJK::DataFrames.DataFrame
    JKL::DataFrames.DataFrame
    KLM::DataFrames.DataFrame
    to::TimerOutput

    function DataFrameData(n::Int)
        return new(
            ["i$i" for i = 1:n],
            parsefile_dataframe(joinpath(data_dir, "data_IJK_$n.json"), (:i, :j, :k)),
            parsefile_dataframe(joinpath(data_dir, "data_JKL.json"), (:j, :k, :l)),
            parsefile_dataframe(joinpath(data_dir, "data_KLM.json"), (:k, :l, :m)),
            TimerOutput(),
        )
    end
end

function dataframe_formulation(data::DataFrameData)
    @timeit data.to "Data manipulation" begin
        ijklm = @timeit data.to "Innerjoin" DataFrames.innerjoin(
            DataFrames.innerjoin(data.IJK, data.JKL; on = [:j, :k]),
            data.KLM;
            on = [:k, :l],
        )
    end
    model = Model(HiGHS.Optimizer)
    set_silent(model)
    @timeit data.to "Create x" begin
        ijklm[!, :x] = @variable(model, x[1:size(ijklm, 1)] >= 0)
    end
    @timeit data.to "Create constraints" begin
        for df in DataFrames.groupby(ijklm, :i)
            @constraint(model, sum(df.x) >= 0)
        end
    end
    # optimize!(model)
    return model
end

struct DuckDBData
    con::DuckDB.DB
    I::Vector{String}
    to::TimerOutput

    function DuckDBData(n::Int, dbfilename = nothing)
        duckdb_db = isnothing(dbfilename) ? ":memory:" : joinpath(@__DIR__, "local-db.duckdb")
        isfile(duckdb_db) && rm(duckdb_db)
        con = DBInterface.connect(DuckDB.DB, duckdb_db)
        to = TimerOutput()
        @timeit to "Read data of size $n" begin
            for (filename, indices) in (
                ("data_IJK_$n.json", (:i, :j, :k)),
                ("data_JKL.json", (:j, :k, :l)),
                ("data_KLM.json", (:k, :l, :m)),
            )
                columns = join(["json[$i] as $idx" for (i, idx) in enumerate(indices)], ", ")
                table_name = "t_" * join(indices)
                filepath = joinpath(data_dir, filename)
                @timeit to "Read $table_name" DuckDB.query(
                    con,
                    "CREATE OR REPLACE TABLE $table_name AS
                    SELECT $columns
                    FROM read_json('$filepath') as json
                    ;",
                )
            end
            return new(con, ["i$i" for i = 1:n], to)
        end
    end
end

function duckdb_formulation(data::DuckDBData)
    @timeit data.to "Data manipulation" begin
        @timeit data.to "Query ijklm" DuckDB.query(
            data.con,
            "CREATE OR REPLACE TEMP SEQUENCE id START 1;
            CREATE OR REPLACE TABLE var_x AS
            SELECT
                nextval('id') AS id,
                t_ijk.i, t_ijk.j, t_ijk.k, t_jkl.l, t_klm.m
            FROM t_ijk
            INNER JOIN t_jkl
                ON  t_ijk.j = t_jkl.j
                AND t_ijk.k = t_jkl.k
            INNER JOIN t_klm
                ON  t_jkl.k = t_klm.k
                AND t_jkl.l = t_klm.l
            ;",
        )
        @timeit data.to "Group ijklm over i" DuckDB.query(
            data.con,
            "CREATE OR REPLACE TEMP SEQUENCE id START 1;
            CREATE OR REPLACE TABLE cons AS
            SELECT
                nextval('id') AS id,
                ARRAY_AGG(var_x.id) AS var_x_indices,
            FROM var_x
            GROUP BY var_x.i
            ;",
        )
    end

    model = Model(HiGHS.Optimizer)
    set_silent(model)
    @timeit data.to "Create x" begin
        # x = model[:x] = [
        #     @variable(
        #         model,
        #         # base_name = "x[...]",
        #         lower_bound = 0.0
        #     ) for row in DuckDB.query(data.con, "FROM var_x")
        # ]
        # Cheaper version because we don't need anything from the rows
        num_vars = only(only(DuckDB.query(data.con, "SELECT COUNT(*) FROM var_x")))
        x = @variable(model, x[1:num_vars] >= 0)
    end
    @timeit data.to "Create constraints" begin
        # for row in DuckDB.query(data.con, "FROM cons")
        #     var_x_indices = row.var_x_indices::Vector{Union{Missing,Int}}
        #     x_expr = AffExpr(0.0)
        #     for id::Int in var_x_indices
        #         add_to_expression!(x_expr, x[id])
        #     end
        #     @constraint(model, x_expr in MOI.GreaterThan(0.0))
        # end
        model[:cons] = [
            @constraint(
                model,
                sum(x[id::Int] for id in row.var_x_indices::Vector{Union{Missing,Int}}) >= 0
            ) for row in DuckDB.query(data.con, "FROM cons")
        ]
    end
    # @timeit data.to "Solve model" optimize!(model)
    return model
end

function compare_timer_outputs(to1::TimerOutput, to2::TimerOutput)
    # Header
    @printf(
        "%-40s :: %11s %11s %11s | %11s %11s %11s\n",
        "Name (to1 / to2)",
        "Time1",
        "Time2",
        "TimeRatio",
        "Allocs1",
        "Allocs2",
        "AllocsRatio"
    )

    @printf("%s\n", "-"^120)
    for (inner_name, inner1) in to1.inner_timers
        # Skip if to1 does not have same inner timer
        if !haskey(to2.inner_timers, inner_name)
            continue
        end
        inner2 = to2.inner_timers[inner_name]

        # Data
        stats = Dict{Symbol,Float64}(
            :time1 => TimerOutputs.time(inner1),
            :time2 => TimerOutputs.time(inner2),
            :allocs1 => TimerOutputs.allocated(inner1),
            :allocs2 => TimerOutputs.allocated(inner2),
        )
        stats[:time_ratio] = stats[:time1] / stats[:time2]
        stats[:allocs_ratio] = stats[:allocs1] / stats[:allocs2]

        # Print
        @printf(
            "%-40s :: %11.5e %11.5e %11.5f | %11.5e %11.5e %11.5f\n",
            inner1.name,
            stats[:time1],
            stats[:time2],
            stats[:time_ratio],
            stats[:allocs1],
            stats[:allocs2],
            stats[:allocs_ratio],
        )
    end

    return nothing
end

function timeroutput_comparison()
    N = 100000
    m = 3
    @info "Running TimerOutput comparison with N=$N for $m+1 repetitions"

    dataframe_data = DataFrameData(N)
    dataframe_formulation(dataframe_data)
    reset_timer!(dataframe_data.to)
    for _ = 1:m
        dataframe_formulation(dataframe_data)
    end

    duckdb_data = DuckDBData(N)
    duckdb_formulation(duckdb_data)
    reset_timer!(duckdb_data.to)
    for _ = 1:m
        duckdb_formulation(duckdb_data)
    end

    @show dataframe_data.to
    @show duckdb_data.to

    return compare_timer_outputs(dataframe_data.to, duckdb_data.to)
end

function timings(; num_samples = 10, num_repetitions = 10)
    N = Int[]
    time_dataframe = Float64[]
    time_duckdb = Float64[]
    memory_dataframe = Float64[]
    memory_duckdb = Float64[]
    gc_time_dataframe = Float64[]
    gc_time_duckdb = Float64[]
    compile_time_dataframe = Float64[]
    compile_time_duckdb = Float64[]

    for file in readdir(joinpath(@__DIR__, "IJKLM", "data"))
        m = match(r"data_IJK_([0-9]*).json", file)
        if isnothing(m)
            continue
        end
        n = parse(Int, m[1])
        # debugging
        # if n > 1000
        #     continue
        # end
        @info "Running $n"

        dataframe_data = DataFrameData(n)
        duckdb_data = DuckDBData(n)
        # First run
        dataframe_formulation(dataframe_data)
        duckdb_formulation(duckdb_data)

        for _ = 1:num_samples
            push!(N, n)

            # Measure DataFrame performance
            stats = @timed for _ = 1:num_repetitions
                dataframe_formulation(dataframe_data)
            end
            push!(time_dataframe, stats.time / num_repetitions)
            push!(memory_dataframe, stats.bytes / num_repetitions / 1e6) # Convert to MB
            push!(gc_time_dataframe, stats.gctime / num_repetitions)
            push!(compile_time_dataframe, stats.compile_time / num_repetitions)

            # Measure DuckDB performance
            stats = @timed for _ = 1:num_repetitions
                duckdb_formulation(duckdb_data)
            end
            push!(time_duckdb, stats.time / num_repetitions)
            push!(memory_duckdb, stats.bytes / num_repetitions / 1e6) # Convert to MB
            push!(gc_time_duckdb, stats.gctime / num_repetitions)
            push!(compile_time_duckdb, stats.compile_time / num_repetitions)
        end
    end

    df = DataFrame(;
        N = N,
        dataframe_time = time_dataframe,
        duckdb_time = time_duckdb,
        dataframe_memory = memory_dataframe,
        duckdb_memory = memory_duckdb,
        dataframe_gc_time = gc_time_dataframe,
        duckdb_gc_time = gc_time_duckdb,
        dataframe_compile_time = compile_time_dataframe,
        duckdb_compile_time = compile_time_duckdb,
    )
    return CSV.write(joinpath(@__DIR__, "timings.csv"), df)
end

function plot_timings()
    filename = joinpath(@__DIR__, "timings.csv")
    if !isfile(filename)
        error("File '$filename' expected but not found")
    end

    df = DataFrame(CSV.File(filename))
    N = maximum(df.N)
    for agg in (mean, median, minimum)
        df_agg =
            combine(
                groupby(df, :N),
                :dataframe_time => agg => :dataframe_time,
                :duckdb_time => agg => :duckdb_time,
                :dataframe_memory => agg => :dataframe_memory,
                :duckdb_memory => agg => :duckdb_memory,
                :dataframe_gc_time => agg => :dataframe_gc_time,
                :duckdb_gc_time => agg => :duckdb_gc_time,
                :dataframe_compile_time => agg => :dataframe_compile_time,
                :duckdb_compile_time => agg => :duckdb_compile_time,
            ) |> sort

        plt_args = (
            xlabel = "|I| (log scale)",
            xaxis = :log,
            c = [:red :blue],
            m = ([:circle :square], stroke(1), [:pink :lightblue]),
            xticks = 10 .^ (1:floor(Int, log10(N))),
            background = nothing,
        )

        plt_time = plot(
            df_agg.N,
            [df_agg.dataframe_time df_agg.duckdb_time];
            labels = hcat("DataFrame", "DuckDB"),
            ylabel = "Time (s) (log scale)",
            yaxis = :log,
            title = "Model Creation Time ($agg)",
            plt_args...,
        )

        plt_memory = plot(
            df_agg.N,
            [df_agg.dataframe_memory df_agg.duckdb_memory];
            labels = hcat("DataFrame", "DuckDB"),
            ylabel = "(MB) (log scale)",
            yaxis = :log,
            title = "Memory Allocations ($agg)",
            plt_args...,
        )

        plt_gc = plot(
            df_agg.N,
            [df_agg.dataframe_gc_time df_agg.duckdb_gc_time];
            yaxis = :log,
            labels = hcat("DataFrame", "DuckDB"),
            ylabel = "GC Time (s) (log scale)",
            title = "Garbage Collection Time ($agg)",
            plt_args...,
        )

        plt_compile = plot(
            df_agg.N,
            [df_agg.dataframe_compile_time df_agg.duckdb_compile_time];
            labels = hcat("DataFrame", "DuckDB"),
            ylabel = "Compilation Time (s)",
            title = "Compilation Time ($agg)",
            plt_args...,
        )

        scatter!(
            plt_time,
            df.N,
            [df.dataframe_time df.duckdb_time];
            lab = "",
            c = [:pink :lightblue],
            opacity = 0.5,
            m = [:circle :square],
        )
        scatter!(
            plt_memory,
            df.N,
            [df.dataframe_memory df.duckdb_memory];
            lab = "",
            c = [:pink :lightblue],
            opacity = 0.5,
            m = [:circle :square],
        )
        scatter!(
            plt_gc,
            df.N,
            [df.dataframe_gc_time df.duckdb_gc_time];
            lab = "",
            c = [:pink :lightblue],
            opacity = 0.5,
            m = [:circle :square],
        )
        scatter!(
            plt_compile,
            df.N,
            [df.dataframe_compile_time df.duckdb_compile_time];
            lab = "",
            c = [:pink :lightblue],
            opacity = 0.5,
            m = [:circle :square],
        )
        figsize = (800, 600)
        path_prefix = joinpath(@__DIR__, "..", "images")
        isdir(path_prefix) || mkdir(path_prefix)
        plot(plt_time; size = figsize)
        png(joinpath(path_prefix, "ijklm-$agg-time"))
        plot(plt_memory; size = figsize)
        png(joinpath(path_prefix, "ijklm-$agg-memory"))
        plot(plt_gc; size = figsize)
        png(joinpath(path_prefix, "ijklm-$agg-gctime"))

        plot(plt_time, plt_memory, plt_gc, plt_compile; layout = (2, 2), size = figsize)
        png(joinpath(path_prefix, "ijklm-$agg-full-comparison"))
    end
end

# timeroutput_comparison()
# timings()
Plots.default(;
    titlefont = 22,
    legendfontsize = 10,
    guidefont = (16, "Times New Roman"),
    tickfontsize = 10,
)
plot_timings()
