# Based on main_IJKLM.py: https://github.com/justine18/performance_experiment/tree/0aa5512e34c9041d719fa8c0763fdc892e021415
import numpy as np
import os

# import submodules
import data_generation as data
import emporium

# --------------------------------

os.makedirs("IJKLM/data", exist_ok=True)

max_cardinality_of_i = 100000
cardinality_of_j = 20

np.random.seed(123)

s7 = 2.65  # close to sqrt(7) so that s7 ** (n % 3) = [1, 3, 7]

N = [round(s7 ** (n % 3)) * 10 ** (n // 3) for n in range(9, 19)]
N = [n for n in N if n <= max_cardinality_of_i]

J, K, L, M, JLK, KLM = data.create_fixed_data(m=cardinality_of_j)
jlk_tuple, klm_tuple = data.fixed_data_to_tuples(JLK, KLM)
jlk_dict, klm_dict = data.fixed_data_to_dicts(jlk_tuple, klm_tuple)

emporium.save_to_json(N, "N", "", "IJKLM")
emporium.save_to_json(jlk_tuple, "JKL", "", "IJKLM")
emporium.save_to_json(klm_tuple, "KLM", "", "IJKLM")

for n in N:
    filepath = emporium.to_filepath("IJK", f"_{n}", "IJKLM")

    print(f"Creating data for n = {n}")
    I, IJK = data.create_variable_data(n=n, j=J, k=K)
    ijk_tuple = data.variable_data_to_tuples(IJK)

    emporium.save_to_json(ijk_tuple, "IJK", f"_{n}", "IJKLM")
