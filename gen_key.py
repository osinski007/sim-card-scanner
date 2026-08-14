machine_code = "4788B8F8E45FAA19"
chars = "0123456789ABCDEFGHJKLMNPQRSTUVWXYZ"
key = ""
seed = int(machine_code, 16)

for i in range(20):
    seed = (seed * 1103515245 + 12345) & 0x7fffffff
    key += chars[seed % len(chars)]
    if i in [4, 9, 14]:
        key += "-"

print(key)