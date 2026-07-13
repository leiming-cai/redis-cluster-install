name: Bug report
about: 创建 bug 报告,帮助我们改进
title: "[Bug] "
labels: ["bug"]
assignees: []

body:
  - type: textarea
    id: what-happened
    attributes:
      label: 发生了什么
      description: 清晰简洁地描述 bug 是什么
      placeholder: |
        在运行 install.sh 时,redis-server 启动失败并报错 "..."
    validations:
      required: true

  - type: textarea
    id: repro
    attributes:
      label: 复现步骤
      description: 触发 bug 的命令序列
      placeholder: |
        1. 准备 2 台 CentOS 7 节点...
        2. 运行 `bash install.sh`
        3. 输入 SSH 凭证...
        4. 看到错误
    validations:
      required: true

  - type: textarea
    id: expected
    attributes:
      label: 预期行为
      description: 你期望发生什么
    validations:
      required: false

  - type: textarea
    id: env
    attributes:
      label: 环境信息
      description: |
        - 控制机 OS:
        - 节点 A OS:
        - 节点 B OS:
        - gcc 版本:
        - Redis 版本:
        - 仓库 commit:
      placeholder: |
        - 控制机: Windows 11 / WSL Ubuntu 22.04
        - 节点: CentOS 7.9 / kernel 3.10
        - gcc: 4.8.5
        - Redis source: 8.8.0
        - commit: b5549a0
    validations:
      required: true

  - type: textarea
    id: logs
    attributes:
      label: 完整日志
      description: 粘贴 install.sh 的完整输出,尤其是报错附近的几行
      render: shell
    validations:
      required: false

  - type: dropdown
    id: severity
    attributes:
      label: 严重程度
      options:
        - 阻塞 — 集群起不来
        - 重要 — 部分功能失败
        - 普通 — 小问题或文档错误
        - 建议 — 改进想法
    validations:
      required: true
