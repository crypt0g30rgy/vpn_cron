import re
from collections import defaultdict

pattern = re.compile(
    r"credentials\[(\d+)\]\.safaricom\.withdraw\.(\w+)=([\s\S]+)"
)

# map input key → output key
mapping = {
    "consumerKey": "CONSUMER_KEY",
    "consumerSecret": "CONSUMER_SECRET",
    "businessShortCode": "SHORTCODE",
    "initiatorName": "INITIATOR",
    "securityCredential": "SECURITY_CREDENTIAL"
}

data = defaultdict(dict)

with open("input.env") as f:
    for line in f:
        line = line.strip()
        m = pattern.search(line)
        if not m:
            continue
        index, key, value = m.groups()
        if key in mapping:
            data[index][mapping[key]] = value

# Sort random indexes and remap to 1..N
sorted_indexes = sorted(data.keys(), key=lambda x: int(x))

with open("output.env", "w") as out:
    for new_num, old_index in enumerate(sorted_indexes, start=1):
        out.write(f"# Account {new_num}\n")
        for field in [
            "CONSUMER_KEY",
            "CONSUMER_SECRET",
            "SHORTCODE",
            "INITIATOR",
            "SECURITY_CREDENTIAL"
        ]:
            if field in data[old_index]:
                out.write(f'{field}_{new_num}="{data[old_index][field]}"\n')
        out.write("\n")
