# Based on IJKLM/help.py: https://github.com/justine18/performance_experiment/tree/0aa5512e34c9041d719fa8c0763fdc892e021415
# Renamed to emporium.py

import pandas as pd
import os
import json


def incremental_range(start, stop, step, inc):
    value = start
    while value < stop:
        yield value
        value += step
        step += inc


def create_data_frame():
    return pd.DataFrame(
        {"I": [], "Language": [], "MeanTime": [], "MedianTime": [], "MinTime": []}
    )


def create_directories(model):
    for d in ["data", "results"]:
        if not os.path.exists(os.path.join(model, d)):
            os.makedirs(os.path.join(model, d))


def to_filepath(name, i, model):
    return os.path.join(model, "data", f"data_{name}{i}.json")


def save_to_json(symbol, name, i, model):
    file = to_filepath(name, i, model)
    with open(file, "w") as f:
        json.dump(list(symbol), f)


def save_to_json_d(d, name, i, model):
    file = to_filepath(name, i, model)
    df = pd.DataFrame([(i, m, d[i, m]) for i, m in d], columns=["i", "m", "value"])
    df.to_json(file, orient="values")


def below_time_limit(df, limit):
    return (df["MinTime"].max() < limit) or (df.empty)


def process_results(r, res_df):
    return pd.concat([res_df, r])


def print_log_message(language, n, df):
    # define a standardized log
    log = "{language:<19} done {n:>6} in {time:>}s"
    print(
        (
            log.format(
                language=language,
                n=n,
                time=round(df["MinTime"].max(), 2),
            )
        )
    )


def save_results(df, solve, model):
    file = (
        os.path.join(model, "results", "experiment_results_solve.csv")
        if solve
        else os.path.join(model, "results", "experiment_results_model.csv")
    )
    df.pivot(index="I", columns="Language", values="MinTime").to_csv(file)
