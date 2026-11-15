占位符：`__APPNAME__` `__DISPLAY_NAME__` `__DESC__` `__PORT__` `__ARCH__` `__WIZARD_TIPS__`。
出现位置：manifest、cmd/common（`APPNAME=`）、config/privilege（username/groupname）、app/ui/config（`.url` 的 key 与 title）、wizard/install、wizard/config。
`__ARCH__` 只能是 x86 / arm / loongarch / risc-v / all。
