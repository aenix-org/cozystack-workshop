# वर्कशॉप चैट संदेश — bastion पथ

एक फ़ाइल, एक संदेश। इन्हें व्यावहारिक काम के साथ-साथ भेजें, सब एक साथ नहीं।

यह सेट उन प्रतिभागियों के लिए है जो **साझा bastion (VM) के ज़रिए** काम करते हैं:
टूल और क्लस्टर तक पहुँच पहले से ही bastion पर हैं, टेनेंट नंबर फ़ाइलों में पहले से
भर दिया गया है, और एप्लिकेशन की जाँच उसके डोमेन नाम से होती है। अपने ख़ुद के लैपटॉप से काम करने वाला सेट
[`../../laptop/chat/`](../../laptop/chat/) में है।

संदेशों की संख्या लैपटॉप सेट के साथ निरंतर चलती है (इसीलिए इसमें अंतराल हैं: टूल
इंस्टॉल करने के बारे में पोस्ट यहाँ ज़रूरी नहीं हैं)।

| # | संदेश | फ़ाइल |
|---|---|---|
| 1 | हम असल में क्या कर रहे हैं | [`01-what-we-are-doing.md`](01-what-we-are-doing.md) |
| 2 | छोटा शब्दकोश: आपकी तरफ़ इसे क्या कहते हैं और यहाँ क्या | [`02-glossary.md`](02-glossary.md) |
| 3 | शुरू करने से पहले: क्या-क्या चाहिए होगा | [`03-prerequisites.md`](03-prerequisites.md) |
| 8 | bastion पर लॉग इन करना | [`08-connect-to-cluster.md`](08-connect-to-cluster.md) |
| 10 | सामग्री पहले से ही bastion पर है | [`10-clone-and-set-number.md`](10-clone-and-set-number.md) |
| 11 | फ़ाइल मैप: क्या कहाँ रहता है और कहाँ चलता है | [`11-file-map.md`](11-file-map.md) |
| 12 | चरण 1. vSphere से इमेज बाहर निकालना | [`12-phase-1-export-image.md`](12-phase-1-export-image.md) |
| 13 | नज़दीक से: 01-bucket.yaml के अंदर क्या है | [`13-bucket-manifest.md`](13-bucket-manifest.md) |
| 14 | स्टेप 1: आपका अपना स्टोरेज | [`14-step-1-bucket.md`](14-step-1-bucket.md) |
| 15 | नज़दीक से: 02-conversion-vm.yaml के अंदर क्या है | [`15-conversion-vm-manifest.md`](15-conversion-vm-manifest.md) |
| 16 | स्टेप 2: कन्वर्टर मशीन | [`16-step-2-conversion-vm.md`](16-step-2-conversion-vm.md) |
| 17 | नज़दीक से: convert.sh क्या करता है | [`17-convert-script.md`](17-convert-script.md) |
| 18 | स्टेप 3: इमेज को कन्वर्ट करना | [`18-step-3-convert-image.md`](18-step-3-convert-image.md) |
| 19 | चरण 2. मशीन को उसके नए घर में चालू करना | [`19-phase-2-new-vm.md`](19-phase-2-new-vm.md) |
| 20 | नज़दीक से: 03-app-vm.yaml के अंदर क्या है | [`20-app-vm-manifest.md`](20-app-vm-manifest.md) |
| 21 | स्टेप 4: आपकी वर्चुअल मशीन | [`21-step-4-your-vm.md`](21-step-4-your-vm.md) |
| 22 | चरण 3. चिड़ियाघर को बाहर फेंकना | [`22-phase-3-managed-services.md`](22-phase-3-managed-services.md) |
| 23 | नज़दीक से: 04-managed.yaml के अंदर क्या है | [`23-managed-manifest.md`](23-managed-manifest.md) |
| 24 | स्टेप 5: कैटलॉग से एक डेटाबेस और एक क़तार | [`24-step-5-database-and-queue.md`](24-step-5-database-and-queue.md) |
| 25 | स्टेप 6: मशीन के अंदर नेटवर्क ठीक करना | [`25-step-6-fix-networking.md`](25-step-6-fix-networking.md) |
| 26 | पहली जाँच: हम इसे चालू करने की कोशिश करते हैं और एक त्रुटि पर पहुँचते हैं | [`26-first-check-fails.md`](26-first-check-fails.md) |
| 27 | स्टेप 7: एप्लिकेशन को प्रबंधित सेवाओं की ओर इंगित करना | [`27-step-7-switch-app.md`](27-step-7-switch-app.md) |
| 28 | स्टेप 8: एप्लिकेशन अब भी क्यों क्रैश होता है | [`28-step-8-why-it-still-fails.md`](28-step-8-why-it-still-fails.md) |
| 29 | स्टेप 8: क्लाइंट इंस्टॉल करना और स्कीमा लागू करना | [`29-step-8-apply-schema.md`](29-step-8-apply-schema.md) |
| 30 | स्टेप 9: पूरी श्रृंखला की पुष्टि करना | [`30-step-9-verify-chain.md`](30-step-9-verify-chain.md) |
| 31 | अगर कुछ काम नहीं कर रहा | [`31-troubleshooting.md`](31-troubleshooting.md) |
| 32 | वर्कशॉप के बाद | [`32-after-the-workshop.md`](32-after-the-workshop.md) |
