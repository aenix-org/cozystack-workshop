## 20. 深入了解：03-app-vm.yaml 里有什么

又是两个对象——一块磁盘和一台机器。

```yaml
kind: VMDisk
spec:
  source:
    http:
      url: "ВСТАВЬТЕ_PRESIGNED_URL"
  storage: 10Gi
```

`source.http` 取代了 `source.image`——这就是与上一阶段的全部区别。这里你要粘贴 `convert.sh` 输出中的那个链接，也就是 `Share:` 一词后面的那个。要完整粘贴，连同问号后面那条长长的「尾巴」一起：这条尾巴就是签名，没有它平台会拒绝访问。

```yaml
kind: VMInstance
spec:
  instanceType: u1.medium
  instanceProfile: centos.7
  disks:
    - name: app-1
```

`instanceProfile: centos.7`——一份针对老系统的虚拟硬件配置。它比看上去更重要：CentOS 7 用的是 2016 年的内核，一部分现代虚拟硬件设置它并不认识。这份配置会挑选出这样一个内核能够处理的那些设置。

顺便说一句，这也正是对「它到底能不能跑老系统」这个问题的通用回答。能跑，只要你告诉平台这个系统是老的。
