# moonsbe 0.2.0 复审版兼容范围

此版本实现一组明确限定的 SBE XML 与 wire-format 能力，参考 SBE 1.0 with Errata November 2020，并固定使用 `sbe-all 1.35.0` 进行互通验证。参考工具版本、Schema 内的业务版本和编码标准版本分别管理。

## 支持矩阵

| 范围 | 0.2.0 行为 |
| --- | --- |
| 消息头 | 按 `headerType` 解析四个必填无符号成员的宽度和偏移，支持显式填充及 `numGroups`、`numVarDataFields` 扩展计数。保留常用的 8 字节布局 |
| 字节序 | littleEndian 与 bigEndian，同时用于头部和消息体 |
| 整数 | `int8/16/32/64`、`uint8/16/32/64`，保留完整 64 位精度 |
| 浮点 | float32 与 float64，按 IEEE 位表示读写，有限数值与可选空值 |
| 字符 | 单字节可打印 ASCII char、定长字符数组、ASCII 与 UTF-8 变长文本 |
| 数组 | 定长基础类型数组，检查元素数与数值范围 |
| 常量 | constant 基础类型、复合类型内常量、枚举 `valueRef` |
| 枚举和集合 | 枚举名与值映射、位选择集合、已知值和 `sinceVersion` 校验 |
| 复合类型 | 内联类型、`ref`、显式 offset 和成员 `sinceVersion`。按消息版本访问有效成员，保留已声明偏移 |
| 必填和可选 | 标量支持标准或自定义 `nullValue`。可选复合字段以首个固定标量的空值表示整体缺失 |
| 数值约束 | minValue、maxValue、nullValue 的物理位宽与运行时范围检查 |
| 重复组 | 按 `dimensionType` 编译 `blockLength` 与 `numInGroup` 的宽度、偏移和范围，支持嵌套组及两种扩展计数 |
| 变长数据 | 无符号 uint8/16/32 长度前缀和 char/uint8 数据，检查 maxValue |
| XML 资源 | 调用方提供内容的 types-root XInclude，保留官方 Car 示例结构 |
| 版本 | 按 acting version 跳过未来字段，按 acting blockLength 跳过已知块末尾的新增固定字段 |
| 生成代码 | MoonBit 记录、枚举和编解码适配器。对根块的定长整数、浮点及数值数组生成直接访问接口，固化偏移、宽度、字节序和版本条件 |

## 明确限制

- 头部与组维度支持表中的标准成员和 `UInt8/16/32/64` 线宽，解析后的长度、标识和计数受运行时整数及消息资源边界约束。扩展计数须与当前已知的消息布局一致。
- 可选数组和可选位集合返回不支持错误。可选复合字段的第一个成员须为非恒量且无版本门槛的固定标量。复合成员的版本控制保留编译时偏移，修改已有偏移或类型仍会被兼容性检查标记。
- 字符编码范围为 ASCII、US-ASCII、UTF-8。ASCII 单字符使用可打印字符范围。
- 枚举未知值和未知集合位按严格模式拒绝。旧 Schema 遇到新增可变字段可能存在无法跳过的字节，完整消息检查会返回错误。
- 定长字符数组使用末尾零填充，数组内容中的内嵌零会被拒绝。
- XML 读取器服务于此 Schema 范围，实施相关语法、布局与约束检查。完整 SBE XSD 合规验证可在宿主系统调用独立标准工具执行。
- DTD、外部实体、XPointer、XInclude 文本模式和任意网络资源加载返回不支持错误。XML 命名空间支持官方示例使用的 SBE Schema 形式。
- 生成的 `view` 校验消息身份、固定块范围、所读字段的版本与访问边界，并直接读取原始字节。整条消息的编解码、值域校验及变长区遍历由共享运行时完成。单字段读取测量见 [互通与性能记录](interoperability.md)。
- CLI 使用 Node.js 文件接口，库的二进制与 Schema 逻辑可由其他包直接调用。

## 资源边界

| 资源 | 默认上限 |
| --- | ---: |
| 一条消息字节数 | 16 MiB |
| Schema XML 长度 | 2,000,000 UTF-16 code units |
| XML 节点数 | 20,000 |
| XML 嵌套深度 | 64 |
| 类型引用深度 | 64 |
| 重复组深度 | 32 |
| 解码累计组项数 | 100,000，可通过参数在支持范围内调整 |
| XInclude 深度 | 16 |

`decode` 要求完整消息边界，先检查范围后读取，每项分配前检查共享数量预算。`compare_schemas` 提供保守的兼容性风险清单，报告描述本运行时的严格解码行为。

0.2.0 的 `Schema`、`GroupDef` 和 `CompositeMember` 记录新增布局或版本字段。使用 `parse_schema` 的调用方可继续走原有入口，手动构造记录的调用方需提供新增字段。

## 对照来源

- [SBE 1.0 with Errata November 2020](https://www.fixtrading.org/wp-content/uploads/download-manager-files/Simple_Binary_Encoding_V1.0_with_Errata_November_2020.pdf)
- [参考实现标签 1.35.0](https://github.com/aeron-io/simple-binary-encoding/tree/1.35.0)
- [本项目固定的上游文件与 JAR 校验值](https://github.com/liyun6666/moonsbe/blob/main/interop/UPSTREAM.md)
