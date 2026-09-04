#!/usr/bin/env bash
# लैब 11 की जाँच: Android बिल्ड पूरी तरह चला, और APK बकेट तक पहुँचा।
#
# हम "Job बना" नहीं, बल्कि तीन अलग-अलग दावों की जाँच करते हैं, और वे एक-दूसरे के बराबर नहीं हैं:
#   1) Job सफलतापूर्वक पूरा हुआ,
#   2) उसके भीतर सचमुच एक APK बना (BUILD SUCCESSFUL),
#   3) फ़ाइल सचमुच ऑब्जेक्ट स्टोरेज तक पहुँची (APK-UPLOADED मार्कर)।
# Job सफलतापूर्वक पूरा हो सकता है और कुछ भी न बना सके — अगर किसी ने स्क्रिप्ट बदल दी हो।
#
# यह VM पर, इसी लैब के फ़ोल्डर से, प्रशिक्षण क्लस्टर `lab` की पहुँच के साथ चलता है
# (प्रबंधन क्लस्टर पर के टेनंट पर नहीं — बिल्ड क्लस्टर में चलता है):
#     export KUBECONFIG=~/lab.kubeconfig
#     cd labs/11-android && ./check.sh
#
# स्क्रिप्ट क्लस्टर में कुछ नहीं बदलती — केवल पढ़ती है और HTTP अनुरोध भेजती है।
# इसे सफ़ाई से पहले चलाएँ: Job को हटाने पर उसके लॉग भी हट जाते हैं, और लॉग के बिना
# ऊपर के तीन में से दो दावों की पुष्टि करने को कुछ नहीं बचता।

# ये दो वेरिएबल lib.sh उठाता है — ये रिपोर्ट के शीर्षक में और फ़ाइल नाम
# report-<लैब>-<तारीख>.md में जाते हैं, जिसे स्क्रिप्ट अपने पास रखती है।
LAB_NAME="11-android"
LAB_TITLE="लैब 11 · क्लस्टर में मोबाइल ऐप की बिल्डिंग"
# साझा जाँच लाइब्रेरी: ok / fail / warn / evidence / finish, क्लस्टर-भीतर का अनुरोध और
# रिपोर्ट लिखना — सब यहीं से आते हैं। पथ इस आधार पर हल होता है कि स्क्रिप्ट खुद
# कहाँ रहती है, इसलिए किसी भी डायरेक्ट्री से चलाने पर एक जैसा काम करता है।
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

# अगर KUBECONFIG सेट नहीं है तो तुरंत रुक जाएँ। इसके बिना kubectl क्लस्टर को
# VM पर ही ढूँढता है, नहीं पाता, और हर जाँच को लगातार एक ही त्रुटि से गिरा देता है,
# जिससे असली कारण दिखाई नहीं देता।
need_kubeconfig

JOB=propusk-build
SECRET=bucket-creds

# सीक्रेट कुंजी का मान। base64 -d हर जगह एक जैसा नहीं होता (BSD बनाम GNU),
# इसलिए हम पायथन से डिकोड करते हैं — जाँच लाइब्रेरी को यह पहले से ही चाहिए।
secret_val() {
  kubectl get secret "$SECRET" -o jsonpath="{.data.$1}" 2>/dev/null \
    | python3 -c 'import sys,base64
d=sys.stdin.read().strip()
print(base64.b64decode(d).decode("utf-8", "replace") if d else "")' 2>/dev/null
}

# --- बकेट पहुँच वाला सीक्रेट -------------------------------------------
# हम यह नहीं जाँचते कि सीक्रेट मौजूद है, बल्कि यह कि उसमें चारों फ़ील्ड भरे हैं।
# सीक्रेट हाथ से बनाया जाता है, लगातार चार --from-literal के साथ, और सबसे आम
# मुसीबत खाली या छूटा हुआ मान है: ऑब्जेक्ट तब सफलतापूर्वक बन जाता है, पर बिल्ड आख़िरी
# चरण पर गिरता है, जब बिल्ड पहले ही निकल चुका होता है। अभी पता लगाना सस्ता है।
if kubectl get secret "$SECRET" >/dev/null 2>&1; then
  MISSING=""
  for k in endpoint bucketName accessKey secretKey; do
    [ -z "$(secret_val "$k")" ] && MISSING="$MISSING $k"
  done
  if [ -z "$MISSING" ]; then
    ok "सीक्रेट ${SECRET} मौजूद है, चारों कुंजियाँ भरी हैं"
    # कुंजियों के मान रिपोर्ट में नहीं जाते — केवल फ़ील्ड के नाम।
    evidence "सीक्रेट ${SECRET} के फ़ील्ड" "endpoint: $(secret_val endpoint)
bucketName: $(secret_val bucketName)
accessKey: <छिपा हुआ>
secretKey: <छिपा हुआ>"
  else
    fail "सीक्रेट ${SECRET} में अधूरे फ़ील्ड हैं:${MISSING}" \
         "README की कमांड से सीक्रेट फिर बनाएँ, मान डैशबोर्ड में लिए जाते हैं: Bucket -> builds -> Secrets"
  fi
else
  fail "क्लस्टर में सीक्रेट ${SECRET} नहीं है" \
       "सीक्रेट बनाएँ: kubectl create secret generic ${SECRET} --from-literal=endpoint=... (चार फ़ील्ड)"
fi

# --- क्या स्टोरेज क्लस्टर के भीतर से पहुँच में है --------------------------
# "Job पाँचवें चरण पर गिरा" का सबसे आम कारण कुंजियाँ नहीं, बल्कि यह है कि
# क्लस्टर से स्टोरेज तक पहुँचा नहीं जा सकता। इसे बिल्ड से अलग जाँचते हैं।
# अनुरोध पॉड से जाता है, VM से नहीं: VM का अपना नेटवर्क और अपने रूट हैं,
# और उसका सफल जवाब इस बारे में कुछ नहीं कहता कि बिल्ड वहाँ पहुँच पाएगी या नहीं।
EP="$(secret_val endpoint)"
if [ -n "$EP" ]; then
  # -k जानबूझकर नहीं: बिल्ड स्टोरेज तक प्रमाणपत्र सत्यापन के साथ जाती है, और जाँच
  # को वहीं गिरना चाहिए जहाँ Job गिरेगा, न कि एक्सपायर्ड सर्ट पर हरा दिखाना चाहिए।
CODE="$(in_cluster_curl "https://${EP}/" "-o /dev/null -w %{http_code}")"
  case "$CODE" in
    2*|3*|4*)
      ok "स्टोरेज ${EP} क्लस्टर के भीतर से जवाब देता है (HTTP ${CODE})"
      evidence "स्टोरेज का जवाब" "GET https://${EP}/ -> HTTP ${CODE}
कोड 403 और 404 यहाँ सामान्य हैं: S3 रूट पर गुमनाम अनुरोध को अस्वीकार होना ही चाहिए।"
      ;;
    5*)
      warn "स्टोरेज ${EP} त्रुटि HTTP ${CODE} से जवाब देता है" \
           "बिल्ड निकल सकती है, पर APK अपलोड नहीं; प्रस्तुतकर्ता को बताएँ"
      ;;
    *)
      fail "स्टोरेज ${EP} क्लस्टर के भीतर से जवाब नहीं देता" \
           "सीक्रेट में endpoint फ़ील्ड जाँचें: यह https:// के बिना और अंत में स्लैश के बिना होना चाहिए"
      ;;
  esac
else
  warn "स्टोरेज की उपलब्धता नहीं जाँच रहा" \
       "पहले endpoint फ़ील्ड वाला सीक्रेट ${SECRET} चाहिए"
fi

# --- Job स्वयं ---------------------------------------------------------------
# हम .status.succeeded देखते हैं, न कि यह कि Job मौजूद है: ऑब्जेक्ट तुरंत और
# हमेशा सफलतापूर्वक बनता है, जबकि कार्य की सफलता का मतलब है कि पॉड कोड 0 के साथ पूरा हुआ।
# पॉड की स्थिति अलग से जाँची जाती है, क्योंकि "अभी भी चल रहा" और "Pending में अटका"
# इंसान के लिए अलग खबर हैं: पहला मतलब इंतज़ार करो, दूसरा मतलब इंतज़ार बेकार है
# और नोड बड़ा करना होगा।
if ! kubectl get job "$JOB" >/dev/null 2>&1; then
  fail "क्लस्टर में Job ${JOB} नहीं है" \
       "बिल्ड शुरू करें: kubectl apply -f android-build.yaml"
else
  SUCCEEDED="$(kubectl get job "$JOB" -o jsonpath='{.status.succeeded}' 2>/dev/null)"
  FAILED="$(kubectl get job "$JOB" -o jsonpath='{.status.failed}' 2>/dev/null)"
  DURATION="$(kubectl get job "$JOB" -o jsonpath='{.status.completionTime}' 2>/dev/null)"
  POD_PHASE="$(kubectl get pods -l "job-name=${JOB}" \
    -o jsonpath='{.items[-1:].status.phase}' 2>/dev/null)"

  if [ "${SUCCEEDED:-0}" -ge 1 ] 2>/dev/null; then
    ok "Job ${JOB} सफलतापूर्वक पूरा हुआ"
    evidence "Job" "$(kubectl get job "$JOB" -o wide 2>/dev/null)
पूरा हुआ: ${DURATION:-अज्ञात}"
  elif [ "$POD_PHASE" = "Pending" ]; then
    fail "बिल्ड पॉड Pending में अटका है — यह शुरू नहीं हुआ और खुद से शुरू नहीं होगा" \
         "कारण देखें: kubectl describe pod -l job-name=${JOB} | grep -A5 Events; Insufficient memory पर नोड को u1.large तक बड़ा करें — कैसे, यह README में लिखा है"
    evidence "बिल्ड पॉड की घटनाएँ" \
      "$(kubectl describe pod -l "job-name=${JOB}" 2>/dev/null | sed -n '/Events:/,$p' | head -20)"
  elif [ "${FAILED:-0}" -ge 1 ] 2>/dev/null; then
    fail "Job ${JOB} त्रुटि के साथ पूरा हुआ (असफल प्रयास: ${FAILED})" \
         "लॉग की आख़िरी पंक्तियाँ देखें: kubectl logs job/${JOB} --tail=40"
    evidence "गिरी हुई बिल्ड के लॉग का अंत" \
      "$(kubectl logs "job/${JOB}" --tail=30 2>/dev/null)"
  else
    fail "Job ${JOB} अभी पूरा नहीं हुआ (पॉड की स्थिति: ${POD_PHASE:-अज्ञात})" \
         "पहली बिल्ड कुछ मिनटों से लेकर पौने घंटे तक लेती है, कनेक्शन पर निर्भर; साथ चलें: kubectl logs -f job/${JOB}"
  fi

  # --- भीतर ठीक-ठीक क्या हुआ ----------------------------------------
  # सफल Job अपने आप में शून्य रिटर्न कोड के अलावा कुछ साबित नहीं करता।
  # इसलिए हम लॉग खोलते हैं और उसमें दो अलग सबूत ढूँढते हैं: BUILD SUCCESSFUL —
  # कि कम्पाइलेशन पूरी तरह चला, और मार्कर पंक्ति APK-UPLOADED, जिसे स्क्रिप्ट
  # फ़ाइल को बकेट में कॉपी करने के बाद ही छापती है। दूसरा पहले से ज़्यादा मज़बूत है: APK बन
  # सकता है और उस पॉड के भीतर पड़ा रह सकता है जो अभी गायब होने वाला है।
  LOGS="$(kubectl logs "job/${JOB}" --tail=-1 2>/dev/null)"
  if [ -z "$LOGS" ]; then
    warn "बिल्ड लॉग उपलब्ध नहीं" \
         "बिल्ड पॉड हट गया या अभी बना नहीं; लॉग के बिना पुष्टि नहीं की जा सकती कि APK सचमुच बना"
  else
    if printf '%s' "$LOGS" | grep -q 'BUILD SUCCESSFUL'; then
      GRADLE_LINE="$(printf '%s' "$LOGS" | grep -m1 'BUILD SUCCESSFUL')"
      ok "APK सचमुच बना (${GRADLE_LINE})"
    else
      fail "लॉग में BUILD SUCCESSFUL पंक्ति नहीं है — कम्पाइलेशन पूरी तरह नहीं चला" \
           "FAILURE वाली पहली पंक्ति ढूँढें: kubectl logs job/${JOB} | grep -n -m1 -A20 FAILURE"
    fi

    UPLOADED="$(printf '%s' "$LOGS" | grep -m1 '^APK-UPLOADED ' | awk '{print $2}')"
    if [ -n "$UPLOADED" ]; then
      ok "APK बकेट तक पहुँचा: ${UPLOADED}"
      evidence "बिल्ड के बाद बकेट की सामग्री" \
        "$(printf '%s' "$LOGS" | sed -n '/5\/5 кладу APK в бакет/,$p' | grep -v '^APK-UPLOADED ' | head -20)"
    else
      fail "APK बना, पर बकेट तक नहीं पहुँचा" \
           "लॉग का अंत देखें: kubectl logs job/${JOB} --tail=20; अक्सर bucketName ही दोषी होता है — इसमें डैशबोर्ड का लंबा नाम चाहिए, 'builds' नहीं"
    fi
  fi
fi

# --- क्या ऐसी बिल्ड के लिए नोड में पर्याप्त जगह है --------------------------
# फ़ैसला नहीं, बल्कि व्याख्या: अगर Job नहीं समाया, तो कारण लगभग हमेशा यहीं है।
BIGGEST_MEM="$(kubectl get nodes -o jsonpath='{range .items[*]}{.status.allocatable.memory}{"\n"}{end}' 2>/dev/null \
  | sort -n | tail -1)"
if [ -n "$BIGGEST_MEM" ]; then
  BIGGEST_H="$(human_bytes "$BIGGEST_MEM")"
  case "$BIGGEST_H" in
    *Gi)
      GB="${BIGGEST_H%Gi}"
      GB_INT="${GB%%.*}"
      if [ "${GB_INT:-0}" -ge 6 ] 2>/dev/null; then
        ok "सबसे बड़ा नोड ${BIGGEST_H} मेमोरी देता है — बिल्ड के लिए पर्याप्त है"
      else
        warn "सबसे बड़ा नोड केवल ${BIGGEST_H} मेमोरी देता है" \
             "बिल्ड अकेले requests के लिए 4Gi माँगती है; अगर Job Pending में अटके, तो नोड प्रकार को u1.large तक बड़ा करें — कैसे, README में लिखा है"
      fi
      ;;
    *)
      warn "नोडों पर एक गीगाबाइट से कम उपलब्ध मेमोरी है (${BIGGEST_H})" \
           "Android बिल्ड वहाँ नहीं समाएगी, नोड प्रकार बड़ा करें — कैसे, README में लिखा है"
      ;;
  esac
  evidence "नोड संसाधन" "$(kubectl get nodes -o wide 2>/dev/null)"
fi

finish
