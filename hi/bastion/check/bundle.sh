#!/usr/bin/env bash
# सभी लैब के परिणामों को सर्टिफिकेशन सिस्टम में अपलोड करने के लिए एक फ़ाइल में इकट्ठा करता है।
#
# महत्वपूर्ण गुण: यह स्क्रिप्ट कुछ भी दोबारा नहीं चलाती। यह वही लेती है जो हर लैब ने
# उस क्षण दर्ज किया जब आपने उसे सबमिट किया था। वरना यह होता: लैब स्वयं आपसे
# अपने पीछे सफ़ाई करने को कहती हैं, और टेनेंट का कोटा सभी सेवाओं को हफ़्तों तक चलाए
# रखने नहीं देता — तो अंत में दोबारा जांच तीन हफ़्ते पहले ईमानदारी से किए गए काम पर
# विफलता दिखा देती।
#
#   ./bundle.sh                 जो कुछ मिला सब इकट्ठा करें
#   ./bundle.sh --rerun 07-redis  एक लैब दोबारा चलाएं और उसका परिणाम अपडेट करें
#
set -uo pipefail

RESULTS_DIR="${COZY_LAB_RESULTS:-$HOME/.cozystack-labs/results}"
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
OUT="${1:-$HOME/cozystack-labs-bundle.json}"

if [ "${1:-}" = "--rerun" ]; then
  lab="${2:?लैब बताएं, उदाहरण: ./bundle.sh --rerun 07-redis}"
  [ -d "$REPO/labs/$lab" ] || { echo "ऐसी कोई लैब नहीं: $lab"; exit 1; }
  echo "$lab फिर से चला रहे हैं…"
  ( cd "$REPO/labs/$lab" && ./check.sh )
  echo "परिणाम अपडेट हो गया, अब ./bundle.sh बिना विकल्पों के चलाएं"
  exit 0
fi

if [ ! -d "$RESULTS_DIR" ] || [ -z "$(ls -A "$RESULTS_DIR" 2>/dev/null)" ]; then
  cat <<'MSG'
कोई परिणाम नहीं मिला।

हर लैब अपना परिणाम तब सहेजती है जब आप उसमें ./check.sh चलाते हैं।
कम से कम एक पूरी करें और जांच चलाएं — फिर यहाँ वापस आएं।

अगर आपने लैब किसी दूसरी मशीन पर की थीं, तो वहाँ से फ़ोल्डर
~/.cozystack-labs/results कॉपी करें या पथ बताएं: COZY_LAB_RESULTS=/path ./bundle.sh
MSG
  exit 1
fi

python3 - "$RESULTS_DIR" "$OUT" "$REPO" <<'PYEOF'
import json, os, sys, glob, datetime

results_dir, out_path, repo = sys.argv[1], sys.argv[2], sys.argv[3]

# कुल कितनी लैब मौजूद हैं — जांच स्क्रिप्ट की मौजूदगी से गिनते हैं।
# सोलहवीं ("सोमवार को क्या करें") में स्क्रिप्ट नहीं है: यह एक टेक्स्ट
# अभ्यास है, और यह ग्रेड में नहीं गिना जाता।
all_labs = sorted(
    os.path.basename(os.path.dirname(p))
    for p in glob.glob(os.path.join(repo, "labs", "*", "check.sh"))
)

labs, uids, versions, problems = [], set(), set(), []
for path in sorted(glob.glob(os.path.join(results_dir, "result-*.json"))):
    try:
        with open(path) as fh:
            d = json.load(fh)
    except Exception as exc:
        problems.append(f"{os.path.basename(path)}: पढ़ी नहीं जा सकती ({exc})")
        continue
    if d.get("schema_version") != 1:
        problems.append(f"{os.path.basename(path)}: अज्ञात फ़ॉर्मेट संस्करण")
        continue
    labs.append(d)
    if d.get("env", {}).get("cluster_uid"):
        uids.add(d["env"]["cluster_uid"])
    if d.get("env", {}).get("kubernetes_server_version"):
        versions.add(d["env"]["kubernetes_server_version"])

passed = sorted(d["lab"] for d in labs if d["verdict"] == "passed")
failed = sorted(d["lab"] for d in labs if d["verdict"] != "passed")
missing = [l for l in all_labs if l not in {d["lab"] for d in labs}]

bundle = {
    "schema_version": 1,
    "kind": "cozystack-labs-bundle",
    "generated_at": datetime.datetime.now(datetime.timezone.utc)
                      .strftime("%Y-%m-%dT%H:%M:%SZ"),
    "labs_total": len(all_labs),
    "labs_passed": len(passed),
    "cluster_uids": sorted(uids),          # एक से अधिक — अलग-अलग क्लस्टर पर की गईं
    "kubernetes_versions": sorted(versions),
    "results": labs,
}
with open(out_path, "w") as fh:
    json.dump(bundle, fh, ensure_ascii=False, indent=1)

# वही सामान्य टेक्स्ट में — ताकि व्यक्ति देख सके कि वह क्या भेज रहा है।
txt = out_path.rsplit(".", 1)[0] + ".txt"
with open(txt, "w") as fh:
    fh.write("Cozystack लैब परिणाम\n")
    fh.write("संग्रहित: %s\n\n" % bundle["generated_at"])
    fh.write("%d / %d लैब पास\n\n" % (len(passed), len(all_labs)))
    for lab in all_labs:
        rec = next((d for d in labs if d["lab"] == lab), None)
        if rec is None:
            mark, extra = "—", "कोई परिणाम नहीं"
        elif rec["verdict"] == "passed":
            mark = "पास"
            extra = "जांच: %d" % len(rec["checks"])
        else:
            mark = "पास नहीं"
            extra = "विफल: %d" % rec["totals"]["fail"]
        fh.write("  %-20s %-9s %s\n" % (lab, mark, extra))
    fh.write("\nक्लस्टर: %d। Kubernetes संस्करण: %s\n"
             % (len(uids), ", ".join(sorted(versions)) or "निर्धारित नहीं"))
    fh.write("\nफ़ाइल में केवल जांच के पहचानकर्ता और उनके परिणाम जाते हैं।\n"
             "इसमें न कोई पता, न कोई नाम, न लॉग की सामग्री है।\n")

print("%d / %d लैब पास।" % (len(passed), len(all_labs)))
if failed:
    print("पास नहीं: %s" % ", ".join(failed))
if missing:
    print("कोई परिणाम नहीं: %s" % ", ".join(missing))
if len(uids) > 1:
    print("\nचेतावनी: परिणाम %d अलग-अलग क्लस्टर से लिए गए हैं। यह अनुमत है, "
          "लेकिन अपलोड पर इस सेट को चिह्नित किया जाएगा।" % len(uids))
for p in problems:
    print("  समस्या: %s" % p)
print("\nअपलोड के लिए फ़ाइल: %s" % out_path)
print("वही सामान्य टेक्स्ट में:  %s" % txt)
print("भेजने से पहले टेक्स्ट फ़ाइल देखें — इसमें वह सब दिखता है जो जाता है।")
PYEOF
