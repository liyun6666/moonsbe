# 独立互通验收与适用场景

## 实际集成场景

1. **跨语言消息交换**。现有 Java 或 C++ 系统使用 SBE Schema 定义消息。MoonBit 程序引用同一 Schema 生成的类型，读取消息字段或产生可被对端解码的二进制消息。
2. **已有二进制记录读取**。调用方从日志、队列或抓取文件取得一条消息的边界，库检查模板和编码范围后解码，CLI 将字段导出为便于检查的 JSON。
3. **消息定义升级验收**。开发者比较新旧 Schema，检查固定字段追加、值域变化、重复组与变长字段变化，再用两种语言的实现做对照测试，将日志保存到 CI。

上述流程面向采用 SBE 的开发团队。项目当前使用公开参考数据完成互通，尚无外部用户采用记录。

## 固定输入

使用上游 `1.35.0` 标签的 `example-schema.xml`、`common-types.xml` 和 `ExampleUsingGeneratedStub.java`。Schema 原有 XInclude 保留。参考工具 `sbe-all-1.35.0.jar` 的 SHA-256 为以下值。

```text
d11f4bb7c71322e3538613b2da18b11625be400465b29a09db80bc9785cea3ab
```

官方 Car Schema 含 45 字节固定区、复合字段、常量字段、枚举、位集合、3 项 fuelFigures、2 项 performanceFigures 及每项 3 个 acceleration 子项，还含 ASCII 与 UTF-8 长度前缀数据。

## 一条命令复现

```sh
moon run tools/interop.mbtx
```

脚本使用 MoonBit `.mbtx` 编写，执行以下检查并逐步记录标准输出、错误输出与退出码。

| 检查 | 判定方式 |
| --- | --- |
| 参考工具完整性 | 先核验下载 JAR 的 SHA-256 |
| Java 编码 | 用固定上游工具生成 Java codec，运行未修改的上游示例编码器 |
| Java → MoonBit | MoonBit 解码 Java 产生的完整消息，将全部 JSON 字段与仓库预期值比较 |
| MoonBit → Java | MoonBit 从独立输入 JSON 编码，Java 参考编码器产生期望字节并逐字节比较 |
| Java 字段遍历 | Java 生成解码器读取完整消息并遍历嵌套重复组和可变数据 |
| 生成器 | 从同一 Schema 生成并编译 MoonBit 类型适配器 |
| 独立消费包 | examples/typed 导入生成类型并检查记录、枚举和嵌套字段，再编码由 Java 校验 |

## 本地实测结果

2026 年 11 月 7 日的完整本地运行通过。消息连同 8 字节头部为 207 字节，Java 编码、MoonBit 编码和生成类型消费包编码得到相同消息字节，其 SHA-256 如下。

```text
0e1649c2f5a2719b2d10c2a9dc6e1aa962d8523fb8c4531052dbdad65528bfe2
```

本地运行环境为 Windows、MoonBit 0.1.20261023、moonc v0.10.17 和 JDK 24.0.1。独立 CI 已在 Ubuntu、固定编译器 v0.10.17+d971670cd、Temurin 24 和 Node.js 22 中重复执行并通过。每次运行清理旧成功标记，失败会停止并保留已产生的日志。

日志位于 `_build/interop-logs`。GitHub Actions 将日志、Java 消息、MoonBit 消息和解码 JSON 归档为 `moonsbe-interop-evidence`。完整测试范围与限制见 compatibility.md。
