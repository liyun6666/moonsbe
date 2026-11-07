# moonsbe

[![CI](https://github.com/liyun6666/moonsbe/actions/workflows/ci.yml/badge.svg)](https://github.com/liyun6666/moonsbe/actions/workflows/ci.yml)

MoonBit 的 SBE 二进制消息编解码与类型化代码生成库。输入现有 SBE XML Schema，生成 MoonBit 结构体、枚举和编解码适配器，用于与 Java、C++ 等系统交换同一消息定义下的二进制数据。

首版提供一个明确限定的 SBE 兼容范围。固定字段、复合类型、嵌套重复组、可变长数据及版本字段都经过测试。官方 Car 样例已完成 Java → MoonBit、MoonBit → Java 和生成类型消费包 → Java 的验证，完整消息为 207 字节，字节逐一一致。

- [兼容范围](docs/compatibility.md)
- [独立互通验收与实际场景](docs/interoperability.md)
- [项目申报书](docs/项目申报书.md)
- [项目提交说明书](docs/项目提交说明书.md)
- [上游版本与来源](https://github.com/liyun6666/moonsbe/blob/main/interop/UPSTREAM.md)

## 快速运行

需要 MoonBit、Node.js 22+。当前验证工具链为 `moon 0.1.20261023`、`moonc v0.10.17`。Java 互通验证另需 JDK 24。首次解析依赖及下载参考工具需要联网。

```sh
moon update
moon test --target js --warn-list=-implicit_impl_as_method --deny-warn
moon run cmd/main --target js --warn-list=-implicit_impl_as_method -- schema interop/upstream/example-schema.xml
moon run cmd/main --target js --warn-list=-implicit_impl_as_method -- encode interop/upstream/example-schema.xml 1 examples/car.json car.bin
moon run cmd/main --target js --warn-list=-implicit_impl_as_method -- decode interop/upstream/example-schema.xml car.bin
```

参考 Schema 保留其 `common-types.xml` XInclude。库调用方显式提供资源内容，CLI 在 Schema 所在目录读取受限的相对路径。

## 类型化代码生成

```sh
moon run cmd/main --target js --warn-list=-implicit_impl_as_method -- generate interop/upstream/example-schema.xml generated/car/messages.mbt
moon fmt generated/car
moon check --target js --warn-list=-implicit_impl_as_method --deny-warn
```

消费包在 `moon.pkg` 中导入生成包。

```text
import {
  "liyun6666/moonsbe/generated/car" @car,
}
```

生成的 `Car` 提供 `Car::decode(bytes)` 和 `car.encode()`。`f_serial_number` 是 `UInt64`，`f_available` 是生成的枚举，重复组为类型化记录数组。`examples/typed` 使用这些接口读取字段并重新编码，其输出由 Java 参考解码器核验。

```sh
moon run tools/interop.mbtx
```

该命令校验参考 JAR 的 SHA-256，执行独立编码、全部字段对照、完整字节比较、生成代码编译和消费包验证。日志位于 `_build/interop-logs`，CI 将日志与二进制文件归档。

生成类型适配器使用共享的动态校验运行时。每份生成源码嵌入 Schema，在包初始化时编译一次。当前版本以可复用性、边界检查和互通正确性为目标，性能指标需另行测量。

## 库接口

根包只依赖 MoonBit core，文件读写位于 CLI 和示例包。主要接口包括以下内容。

| 接口 | 用途 |
| --- | --- |
| `parse_schema(xml, includes=...)` | 编译 XML Schema，解析类型、布局和显式提供的 XInclude |
| `value_from_json(schema, template_id, source)` | 根据 Schema 读取消息 JSON，保留整数精度并拒绝重复键 |
| `encode(schema, template_id, value, version=...)` | 编码一条包含标准 8 字节消息头的完整消息 |
| `decode(schema, bytes, max_entries=...)` | 解码一条已有边界的完整消息，检查长度与资源上限 |
| `generate_moonbit(xml, includes=...)` | 生成可编译的类型化 MoonBit 适配器 |
| `compare_schemas(old, newer)` | 检查此运行时下的双向版本兼容风险 |

`Value` 区分 `Signed(Int64)`、`Unsigned(UInt64)`、`Floating(Double)`、`Text`、`Binary`、`Record`、`Sequence` 和 `Absent`。JSON 输入可使用精确整数文本或十进制字符串，输出整数统一采用字符串，二进制值采用十六进制字符串。

Schema 的集合公开用于检查与代码生成，调用方应将编译结果视为只读。校验错误使用 `SbeError`，包含 Schema 位置、字段原因或消息偏移信息。

## CLI

以下命令加上前缀 `moon run cmd/main --target js --warn-list=-implicit_impl_as_method --`。

```text
schema SCHEMA.xml
encode SCHEMA.xml TEMPLATE_ID MESSAGE.json OUTPUT.bin
decode SCHEMA.xml INPUT.bin [OUTPUT.json]
generate SCHEMA.xml OUTPUT.mbt
compare OLD_SCHEMA.xml NEW_SCHEMA.xml
hex INPUT.bin
```

校验或文件操作失败返回退出码 `2`。Schema 比较发现兼容性风险返回 `3`。消息边界由调用方的传输层或文件协议提供，每次 `decode` 处理一条完整消息。

## 验证与代码统计

```sh
moon fmt --check
moon check --target js --warn-list=-implicit_impl_as_method --deny-warn
moon test --target js --warn-list=-implicit_impl_as_method --deny-warn
moon test --target wasm-gc -p liyun6666/moonsbe --warn-list=-implicit_impl_as_method --deny-warn
moon run tools/interop.mbtx
moon run tools/stats.mbtx
```

统计脚本需要 ripgrep，将手写实现与测试分开，排除生成代码、上游 Java/XML、接口文件、工具脚本、文档与构建结果。测试覆盖截断、越界、整数范围、空值、名称冲突、嵌套组、字符编码和版本变化。`implicit_impl_as_method` 为当前 MoonBit 派生方法迁移告警，其余告警作为错误处理。

## 来源与许可证

MoonBit 实现按 SBE 公开规范编写，项目采用 Apache License 2.0。互通所需的上游 Schema 与示例 Java 源码来自 `aeron-io/simple-binary-encoding` 的 `1.35.0` 标签，保留原始内容与版权声明。引用材料和生成产物按独立类别统计。详情见 LICENSE、NOTICE 和 interop/UPSTREAM.md。
