## 27. स्टेप 7: एप्लिकेशन को प्रबंधित सेवाओं पर स्विच करें

**हार्डकोड किए गए पतों को नामों से बदलें**

📍 **कहाँ:** आपकी VM के अंदर, रीबूट के बाद।

📄 यह `scripts/connect-managed.sh` की सामग्री है। इसे भी हाथ से टाइप करें — उसी कारण से, और क्योंकि यहाँ केवल तीन कमांड हैं।

मशीन के अंदर, एप्लिकेशन का कॉन्फ़िग खोलें:
```bash
cat /etc/orders/application.properties
```
आपको वही `192.168.10.30` और `192.168.10.40` दिखेंगे। यही हर legacy सिस्टम की तकलीफ़ है: अब किसी को याद नहीं कि ठीक ये पते ही क्यों हैं।

इन्हें सेवाओं के नामों से बदलें (`XX` की जगह अपना नंबर डालें):
```bash
sed -i 's|192.168.10.30|postgres-db-rw.tenant-workshopXX.svc.cozy.local|g' /etc/orders/application.properties
sed -i 's|192.168.10.40|kafka-kafka-kafka-bootstrap.tenant-workshopXX.svc.cozy.local|g' /etc/orders/application.properties
systemctl restart orders-api
```
(दो कमांड, एक में लाइन-ब्रेक के साथ नहीं: चैट से कॉपी करते समय लाइन-ब्रेक अक्सर खो जाता है, और कमांड आधी ही चलती है)

जाँचें:
```bash
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8080/actuator/health
```
`200` — एप्लिकेशन को डेटाबेस और क़तार दोनों दिख रहे हैं। अगर `503` मिले, तो नेटवर्किंग वाले स्टेप पर वापस जाएँ; सबसे संभावित बात यह है कि पता बदला ही नहीं।
