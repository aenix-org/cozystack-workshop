#!/usr/bin/env bash
# लैब 11 की जाँच: Android बिल्ड पूरा चला, और APK बकेट तक पहुँचा।
#
# हम "Job बना" नहीं जाँचते, बल्कि तीन अलग-अलग दावे जाँचते हैं, और वे एक-दूसरे के बराबर नहीं हैं:
#   1) Job सफलतापूर्वक पूरा हुआ,
#   2) उसके भीतर वास्तव में एक APK बना (BUILD SUCCESSFUL),
#   3) फ़ाइल वास्तव में ऑब्जेक्ट स्टोरेज तक पहुँची (APK-UPLOADED मार्कर)।
# कोई Job सफलतापूर्वक पूरा हो सकता है और कुछ भी न बनाए — अगर किसी ने स्क्रिप्ट बदल दी हो।
#
# यह नोटबुक पर, इसी लैब के फ़ोल्डर से चलता है, प्रशिक्षण क्लस्टर `lab` तक पहुँच का उपयोग करते हुए
# (प्रबंधन क्लस्टर पर टेनेंट तक नहीं — बिल्ड क्लस्टर में चलता है):
#     export KUBECONFIG=~/lab.kubeconfig
#     cd labs/11-android && ./check.sh
#
# स्क्रिप्ट क्लस्टर में कुछ नहीं बदलती — यह केवल पढ़ती है और HTTP अनुरोध भेजती है।
# इसे सफ़ाई से पहले चलाएँ: Job हटाने पर उसके लॉग भी हट जाते हैं, और लॉग के बिना ऊपर के
# तीन में से दो दावों की पुष्टि के लिए कुछ नहीं बचता।

# इन दो वेरिएबल्स को lib.sh उठाता है — ये रिपोर्ट के शीर्षक में और उस फ़ाइल के नाम
# report-<लैब>-<तारीख>.md में जाते हैं, जिसे स्क्रिप्ट अपने पास रखती है।
LAB_NAME="11-android"
LAB_TITLE="लैब 11 · क्लस्टर में मोबाइल ऐप बनाना"
# साझा जाँच लाइब्रेरी: यहीं से ok / fail / warn / evidence / finish आते हैं,
# क्लस्टर के भीतर से अनुरोध और रिपोर्ट लिखना। पथ वहीं से हल होता है जहाँ स्क्रिप्ट
# स्वयं है, इसलिए किसी भी डायरेक्टरी से चलाना एक जैसा काम करता है।
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

# अगर KUBECONFIG सेट नहीं है तो तुरंत रुक जाएँ। इसके बिना kubectl क्लस्टर को
# नोटबुक पर ही ढूँढता है, नहीं पाता, और सभी जाँचों को एक के बाद एक उसी त्रुटि से गिरा देता है,
# जिससे असली कारण दिखाई नहीं देता।
need_kubeconfig

JOB=propusk-build
SECRET=bucket-creds

# सीक्रेट key का मान। base64 -d हर जगह एक जैसा नहीं होता (BSD बनाम GNU),
# इसलिए हम python से डिकोड करते हैं — यह जाँच लाइब्रेरी को पहले से ही चाहिए।
secret_val() {
  kubectl get secret "$SECRET" -o jsonpath="{.data.$1}" 2>/dev/null \
    | python3 -c 'import sys,base64
d=sys.stdin.read().strip()
print(base64.b64decode(d).decode("utf-8", "replace") if d else "")' 2>/dev/null
}

# --- बकेट तक पहुँच वाला सीक्रेट -------------------------------------------
# हम सीक्रेट के अस्तित्व को नहीं, बल्कि यह जाँचते हैं कि उसमें चारों फ़ील्ड भरे हुए हैं।
# सीक्रेट हाथ से बनाया जाता है, लगातार चार --from-literal के साथ, और सबसे आम मुसीबत है
# खाली या छूटा हुआ मान: ऑब्जेक्ट तब भी सफलतापूर्वक बन जाता है, पर बिल्ड आख़िरी चरण पर गिरता है,
# जब बिल्ड पहले ही निकल चुका होता है। अभी पता कर लेना सस्ता है।
if kubectl get secret "$SECRET" >/dev/null 2>&1; then
  MISSING=""
  for k in endpoint bucketName accessKey secretKey; do
    [ -z "$(secret_val "$k")" ] && MISSING="$MISSING $k"
  done
  if [ -z "$MISSING" ]; then
    ok "सीक्रेट ${SECRET} मौजूद है, चारों keys भरे हुए हैं"
    # key के मान रिपोर्ट में नहीं जाते — केवल फ़ील्ड के नाम।
    evidence "सीक्रेट ${SECRET} के फ़ील्ड" "endpoint: $(secret_val endpoint)
bucketName: $(secret_val bucketName)
accessKey: <छिपा हुआ>
secretKey: <छिपा हुआ>"
  else
    fail "सीक्रेट ${SECRET} में ये फ़ील्ड भरे नहीं हैं:${MISSING}" \
         "README की कमांड से सीक्रेट फिर से बनाएँ, मान डैशबोर्ड में लिए जाते हैं: Bucket -> builds -> Secrets"
  fi
else
  fail "क्लस्टर में सीक्रेट ${SECRET} नहीं है" \
       "सीक्रेट बनाएँ: kubectl create secret generic ${SECRET} --from-literal=endpoint=... (चार फ़ील्ड)"
fi

# --- क्या क्लस्टर के भीतर से स्टोरेज तक पहुँचा जा सकता है --------------------------
# "Job पाँचवें चरण पर गिरा" का सबसे आम कारण keys नहीं, बल्कि यह है कि क्लस्टर से
# स्टोरेज तक पहुँचा नहीं जा सकता। हम इसे बिल्ड से अलग जाँचते हैं।
# अनुरोध एक pod से जाता है, नोटबुक से नहीं: नोटबुक का अपना नेटवर्क और अपने रूट होते हैं,
# और उसका सफल उत्तर इस बारे में कुछ नहीं कहता कि बिल्ड वहाँ तक पहुँच पाएगा या नहीं।
EP="$(secret_val endpoint)"
if [ -n "$EP" ]; then
  # -k जानबूझकर नहीं: बिल्ड सर्टिफ़िकेट जाँच के साथ स्टोरेज से बात करता है, और जाँच
  # वहीं गिरनी चाहिए जहाँ Job गिरेगा, न कि समय-सीमा बीत चुके सर्ट पर हरा दिखाए।
CODE="$(in_cluster_curl "https://${EP}/" "-o /dev/null -w %{http_code}")"
  case "$CODE" in
    2*|3*|4*)
      ok "स्टोरेज ${EP} क्लस्टर के भीतर से जवाब देता है (HTTP ${CODE})"
      evidence "स्टोरेज का उत्तर" "GET https://${EP}/ -> HTTP ${CODE}
कोड 403 और 404 यहाँ सामान्य हैं: S3 रूट पर गुमनाम अनुरोध अस्वीकार होना ही चाहिए।"
      ;;
    5*)
      warn "स्टोरेज ${EP} त्रुटि HTTP ${CODE} के साथ जवाब देता है" \
           "बिल्ड निकल सकता है, पर APK अपलोड नहीं; प्रस्तुतकर्ता को बताएँ"
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

# --- स्वयं Job ---------------------------------------------------------------
# हम .status.succeeded देखते हैं, Job के अस्तित्व को नहीं: ऑब्जेक्ट तुरंत और हमेशा
# सफलतापूर्वक बनता है, जबकि task की सफलता का मतलब है pod कोड 0 के साथ समाप्त हुआ।
# pod की स्थिति अलग से जाँची जाती है, क्योंकि "अभी भी चल रहा" और "Pending में अटका" इंसान के
# लिए अलग-अलग ख़बर हैं: पहला मतलब इंतज़ार करें, दूसरा मतलब इंतज़ार बेकार है
# और नोड को बड़ा करना होगा।
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
समाप्त हुआ: ${DURATION:-अज्ञात}"
  elif [ "$POD_PHASE" = "Pending" ]; then
    fail "बिल्ड pod Pending में अटका है — यह शुरू नहीं हुआ और अपने आप शुरू नहीं होगा" \
         "कारण देखें: kubectl describe pod -l job-name=${JOB} | grep -A5 Events; Insufficient memory पर नोड को u1.large तक बड़ा करें — यह कैसे करना है, README में लिखा है"
    evidence "बिल्ड pod की घटनाएँ" \
      "$(kubectl describe pod -l "job-name=${JOB}" 2>/dev/null | sed -n '/Events:/,$p' | head -20)"
  elif [ "${FAILED:-0}" -ge 1 ] 2>/dev/null; then
    fail "Job ${JOB} त्रुटि के साथ समाप्त हुआ (असफल प्रयास: ${FAILED})" \
         "लॉग की अंतिम पंक्तियाँ देखें: kubectl logs job/${JOB} --tail=40"
    evidence "असफल बिल्ड लॉग का अंतिम भाग" \
      "$(kubectl logs "job/${JOB}" --tail=30 2>/dev/null)"
  else
    fail "Job ${JOB} अभी तक समाप्त नहीं हुआ (pod की स्थिति: ${POD_PHASE:-अज्ञात})" \
         "पहला बिल्ड कुछ मिनटों से लेकर पौन घंटे तक लेता है, कनेक्शन पर निर्भर; देखते रहें: kubectl logs -f job/${JOB}"
  fi

  # --- भीतर वास्तव में क्या हुआ ----------------------------------------
  # सफल Job अपने आप में शून्य रिटर्न कोड के अलावा कुछ साबित नहीं करता।
  # इसलिए हम लॉग खोलते हैं और उसमें दो अलग-अलग प्रमाण ढूँढते हैं: BUILD SUCCESSFUL —
  # कि संकलन पूरा हुआ, और मार्कर पंक्ति APK-UPLOADED, जिसे स्क्रिप्ट केवल फ़ाइल को बकेट में
  # कॉपी करने के बाद प्रिंट करती है। दूसरा पहले से मज़बूत है: APK बन सकता है
  # और उस pod के भीतर पड़ा रह सकता है, जो अभी ग़ायब होने वाला है।
  LOGS="$(kubectl logs "job/${JOB}" --tail=-1 2>/dev/null)"
  if [ -z "$LOGS" ]; then
    warn "बिल्ड लॉग उपलब्ध नहीं" \
         "बिल्ड pod हटा दिया गया या अभी बना नहीं; लॉग के बिना यह पुष्टि नहीं हो सकती कि APK वास्तव में बना"
  else
    if printf '%s' "$LOGS" | grep -q 'BUILD SUCCESSFUL'; then
      GRADLE_LINE="$(printf '%s' "$LOGS" | grep -m1 'BUILD SUCCESSFUL')"
      ok "APK वास्तव में बना (${GRADLE_LINE})"
    else
      fail "लॉग में BUILD SUCCESSFUL पंक्ति नहीं है — संकलन पूरा नहीं हुआ" \
           "FAILURE वाली पहली पंक्ति ढूँढें: kubectl logs job/${JOB} | grep -n -m1 -A20 FAILURE"
    fi

    UPLOADED="$(printf '%s' "$LOGS" | grep -m1 '^APK-UPLOADED ' | awk '{print $2}')"
    if [ -n "$UPLOADED" ]; then
      ok "APK बकेट तक पहुँचा: ${UPLOADED}"
      evidence "बिल्ड के बाद बकेट की सामग्री" \
        "$(printf '%s' "$LOGS" | sed -n '/5\/5 кладу APK в бакет/,$p' | grep -v '^APK-UPLOADED ' | head -20)"
    else
      fail "APK बना, पर बकेट तक नहीं पहुँचा" \
           "लॉग का अंतिम भाग देखें: kubectl logs job/${JOB} --tail=20; अक्सर bucketName ही दोषी होता है — इसमें डैशबोर्ड का लंबा नाम चाहिए, 'builds' नहीं"
    fi
  fi
fi

# --- क्या ऐसी बिल्ड के लिए नोड में पर्याप्त जगह है --------------------------------
# फ़ैसला नहीं, बल्कि व्याख्या: अगर Job नहीं समाया, तो कारण लगभग हमेशा यहीं होता है।
BIGGEST_MEM="$(kubectl get nodes -o jsonpath='{range .items[*]}{.status.allocatable.memory}{"\n"}{end}' 2>/dev/null \
  | sort -n | tail -1)"
if [ -n "$BIGGEST_MEM" ]; then
  BIGGEST_H="$(human_bytes "$BIGGEST_MEM")"
  case "$BIGGEST_H" in
    *Gi)
      GB="${BIGGEST_H%Gi}"
      GB_INT="${GB%%.*}"
      if [ "${GB_INT:-0}" -ge 6 ] 2>/dev/null; then
        ok "सबसे बड़ा नोड ${BIGGEST_H} मेमोरी देता है — बिल्ड के लिए पर्याप्त"
      else
        warn "सबसे बड़ा नोड केवल ${BIGGEST_H} मेमोरी देता है" \
             "बिल्ड अकेले requests में 4Gi माँगती है; अगर Job Pending में अटका है, तो नोड टाइप को u1.large तक बड़ा करें — कैसे, README में लिखा है"
      fi
      ;;
    *)
      warn "नोड्स में एक गीगाबाइट से कम उपलब्ध मेमोरी है (${BIGGEST_H})" \
           "Android बिल्ड वहाँ नहीं समाएगी, नोड टाइप बड़ा करें — कैसे, README में लिखा है"
      ;;
  esac
  evidence "नोड्स के संसाधन" "$(kubectl get nodes -o wide 2>/dev/null)"
fi

finish
