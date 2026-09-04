## 29. स्टेप 8: क्लाइंट इंस्टॉल करें और स्कीमा लागू करें

**डेटाबेस एक्सेस:**
```
host:     postgres-db-rw.tenant-workshopXX.svc.cozy.local
database: orders
login:    orders
password: Orders2019!
```
पासवर्ड `manifests/04-managed.yaml` में सेट है; इसे कहीं और ढूँढने की ज़रूरत नहीं।

⚠️ **CentOS 7 का डिफ़ॉल्ट psql काम नहीं करेगा।** यह वर्शन 9.2 है, और हमारे डेटाबेस को
SCRAM ऑथेंटिकेशन चाहिए, जिसे यह हैंडल नहीं कर सकता, इसलिए यह जवाब देता है:
`psql: SCRAM authentication requires libpq version 10 or above`. आपको वर्शन 10 या उससे नया क्लाइंट चाहिए।
हम इसे PGDG रिपॉज़िटरी से लेते हैं — CentOS 7 के लिए वहाँ अधिकतम 15 उपलब्ध है।

एक के बाद एक तीन कमांड, हर एक की एक वजह:

```bash
# 1. PGDG रिपॉज़िटरी जोड़ें — PostgreSQL पैकेजों का स्रोत।
yum install -y https://download.postgresql.org/pub/repos/yum/reporpms/EL-7-x86_64/pgdg-redhat-repo-latest.noarch.rpm

# 2. libzstd लाइब्रेरी, जिसके बिना क्लाइंट इंस्टॉल नहीं होगा। यह CentOS 7 के
#    रिपॉज़िटरी में नहीं है, इसलिए हम इसे EPEL आर्काइव से लेते हैं।
yum install -y https://archives.fedoraproject.org/pub/archive/epel/7/x86_64/Packages/l/libzstd-1.5.5-1.el7.x86_64.rpm

# 3. क्लाइंट खुद — केवल सक्रिय pgdg15 रिपॉज़िटरी से।
yum install -y --disablerepo='pgdg*' --enablerepo=pgdg15 postgresql15
```

दूसरी और तीसरी कमांड ग़ैर-ज़रूरी लगती हैं, लेकिन इनके बिना इंस्टॉल फ़ेल हो जाता है, और वरना
आप दोनों त्रुटियाँ अपनी आँखों से देखते:

- `libzstd` के बिना — `Requires: libzstd >= 1.4.0`;
- `--disablerepo`/`--enablerepo` के बिना — `HTTPS Error 410 - Gone`. रिपॉज़िटरी पैकेज
  एक साथ PostgreSQL के हर वर्शन को खींच लाता है, जिनमें सपोर्ट से हटाए गए 12 और 13 भी शामिल हैं, और
  इंस्टॉल से पहले `yum` **हर** सक्रिय रिपॉज़िटरी से गुज़रता है और पहले ही बंद पड़े रिपॉज़िटरी पर फ़ेल हो जाता है।
  हम स्पष्ट रूप से केवल उसी को रखते हैं जिसकी हमें ज़रूरत है।

जाँचें कि क्लाइंट अपनी जगह है:

```bash
psql --version
```

अगर जवाब `command not found` है, तो क्लाइंट आपके `PATH` से बाहर पड़ा है; उसे ढूँढें और
मौजूदा सेशन के लिए उसका डायरेक्टरी जोड़ें:

```bash
ls /usr/pgsql-*/bin/psql
export PATH="$PATH:/usr/pgsql-15/bin"
psql --version
```

**स्कीमा फ़ाइल ले लें** — मशीन के पास नेटवर्क पहले से है:

```bash
curl -fsSLO https://raw.githubusercontent.com/aenix-org/cozystack-migration-workshop/master/laptop/scripts/orders-schema.sql
```

**इसे लागू करें।** आइए कमांड को हिस्सा-दर-हिस्सा समझें, ताकि आप आँख मूँदकर टाइप न करें:

```bash
PGPASSWORD='Orders2019!' psql -h postgres-db-rw.tenant-workshopXX.svc.cozy.local \
  -U orders -d orders -f orders-schema.sql
```

- `PGPASSWORD='...'` — पासवर्ड एक एनवायरनमेंट वेरिएबल के ज़रिए दिया जाता है, ताकि `psql` इसे
  इंटरैक्टिव तरीके से न पूछे। स्क्रिप्ट्स में ऐसे ही किया जाता है।
- `-h postgres-db-rw.tenant-workshopXX.svc.cozy.local` — डेटाबेस का पता। यह **कोई IP नहीं**,
  बल्कि क्लस्टर के भीतर एक आंतरिक नाम है। `-rw` सफ़िक्स मायने रखता है: प्रबंधित Postgres की कई
  कॉपियाँ होती हैं, और यह नाम हमेशा उसी की ओर इशारा करता है जिसमें आप **लिख सकते हैं**। `-ro` वाला
  एक जोड़ीदार नाम भी है — केवल पढ़ने के लिए। जब कॉपियों के बीच भूमिकाएँ बदलती हैं, नाम नहीं बदलता,
  इसीलिए एप्लिकेशन की सेटिंग्स में किसी ख़ास सर्वर के पते के बजाय यही नाम रखा जाता है।
- `-U orders` — किस यूज़र के रूप में कनेक्ट करना है, `-d orders` — किस डेटाबेस में।
- `-f orders-schema.sql` — फ़ाइल से कमांड चलाएँ।

डेटाबेस तक IP के बजाय एक स्थिर नाम से पहुँचने की यही क्षमता कॉपियों के स्विच होने को एप्लिकेशन के
लिए अदृश्य बनाती है। पुरानी मशीन पर आपके कॉन्फ़िग में `localhost` था, और वहाँ स्विचिंग जैसी कोई
चीज़ थी ही नहीं।

जाँचें कि टेबल अपनी जगह है:

```bash
PGPASSWORD='Orders2019!' psql -h postgres-db-rw.tenant-workshopXX.svc.cozy.local \
  -U orders -d orders -c '\dt'
```

अगर वह मौजूद है, तो अब ऑर्डर बन जाएगा। इसे हम अगले स्टेप में, पूरी चेन के साथ, जाँचेंगे।
