# IJKLM

## Generate data

Arbitrarily, we choose `uv` to run the Python file with the right project and environment, mostly because it's a single line.
You can run the `main.py` file however you want.

```bash
uv run main.py # in this folder
```

You should now have a subfolder `IJKLM/data` with a bunch of `.json` files.

## Run Julia comparison

Open `julia` in this folder, activate and instantiate the project, and

```julia-repl
julia> # press ]
pkg> activate . # assuming this folder
pkg> instantiate
pkg> # press backspace
julia> include("main.jl")
```
