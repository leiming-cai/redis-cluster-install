name: Feature request
about: 建议新功能或改进
title: "[Feature] "
labels: ["enhancement"]
assignees: []

body:
  - type: textarea
    id: problem
    attributes:
      label: 解决的问题
      description: 这个功能解决什么痛点?
    validations:
      required: true

  - type: textarea
    id: solution
    attributes:
      label: 期望的解决方案
      description: 你希望怎么实现?
    validations:
      required: true

  - type: textarea
    id: alternatives
    attributes:
      label: 备选方案
      description: 还有其他方式吗?
    validations:
      required: false

  - type: textarea
    id: context
    attributes:
      label: 额外信息
      description: |
        - 部署规模(节点数、数据量)
        - 是否愿意贡献 PR
        - 相关 issue
    validations:
      required: false
