## 20. 詳しく見る: 03-app-vm.yaml の中身

ここでも 2 つのオブジェクト、ディスクとマシンです。

```yaml
kind: VMDisk
spec:
  source:
    http:
      url: "ВСТАВЬТЕ_PRESIGNED_URL"
  storage: 10Gi
```

`source.image` ではなく `source.http` になっている、これが前フェーズとの違いのすべてです。ここには `convert.sh` の出力に現れるリンク、`Share:` という単語の後に出てくるものを貼り付けます。疑問符の後ろに続く長い「しっぽ」も含めて、丸ごと貼り付けてください。そのしっぽこそが署名であり、これがないとプラットフォームはアクセスを拒否されます。

```yaml
kind: VMInstance
spec:
  instanceType: u1.medium
  instanceProfile: centos.7
  disks:
    - name: app-1
```

`instanceProfile: centos.7` は、古いシステム向けの仮想ハードウェアのプロファイルです。これは見た目以上に重要です。CentOS 7 のカーネルは 2016 年のもので、最新の仮想ハードウェア設定の一部はそれには理解できません。プロファイルは、そうしたカーネルが扱える設定だけを選び出します。

ちなみにこれが、「そもそも古いシステムでも動くのか」という問いへの一般的な答えでもあります。動きます。ただし、そのシステムは古いのだとプラットフォームに伝えてやればの話です。
