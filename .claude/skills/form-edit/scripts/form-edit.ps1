# form-edit v1.20 — Edit 1C managed form elements
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
[CmdletBinding(PositionalBinding=$false)]
param(
	[Parameter(Mandatory)]
	[Alias('Path')]
	[string]$FormPath,

	[Parameter(Mandatory)]
	[string]$JsonPath
)

$ErrorActionPreference = "Stop"

# --- Разбор пользовательского JSON ---
# Одна строка в stderr вместо дампа исключения ConvertFrom-Json (issue #80): агент по стектрейсу
# идёт чинить скрипт, а не свой вызов. $source — файл или параметр. $expected заполняем только
# для полиморфного входа: у файла подсказка была бы наполнителем. -Inline печатает ещё и то,
# что доехало: у файла такого вопроса нет — путь назван, позицию дал парсер, файл на диске.
# Возврат через -NoEnumerate: без него одноэлементный
# JSON-массив разворачивался бы в скаляр вторым анруллингом.
function ConvertFrom-JsonInput([string]$text, [string]$source, [string]$expected, [switch]$Inline) {
	try {
		# PS 5.1 на пустой строке отдаёт $null, а не ошибку — навык уходил дальше с $null,
		# тогда как py-порт падал. Проверяем сами, чтобы порты вели себя одинаково.
		if ([string]::IsNullOrWhiteSpace($text)) { throw 'input is empty' }
		$parsed = $text | ConvertFrom-Json
	} catch {
		$what = if ($expected) { "$source expects $expected" } else { "Invalid JSON in $source" }
		if ($Inline) {
			$got = ($text -replace '\s+', ' ').Trim()
			$label = 'got'
			if (-not $got) { $got = '(empty)' }
			elseif ($got.Length -gt 60) { $label = 'got (first 60 chars)'; $got = $got.Substring(0, 60) }
			$what = "${what}, ${label}: ${got}"
		}
		[Console]::Error.WriteLine("[ERROR] ${what} ($($_.Exception.Message))")
		exit 1
	}
	Write-Output -NoEnumerate $parsed
}

# --- Чтение входного JSON-файла ---
# Кодировку берём из BOM — это объявление самого файла, а не догадка. Без BOM ждём строгий UTF-8:
# Get-Content -Encoding UTF8 на файле в cp1251 тихо меняет кириллицу на U+FFFD, JSON после этого
# разбирается успешно, и в конфигурацию уезжает имя из «замен». Кодовую страницу не подбираем:
# угаданное имя уйдёт в метаданные так же молча.
function Read-JsonInputFile([string]$path) {
	# Проверка здесь, а не по навыкам: часть навыков проверяла путь сама, часть — нет, и один и тот
	# же промах давал то внятную строку, то дамп MethodInvocationException. Навыки со своей
	# проверкой срабатывают раньше и сохраняют свой текст.
	if (-not (Test-Path -LiteralPath $path)) {
		[Console]::Error.WriteLine("[ERROR] File not found: $path")
		exit 1
	}
	if (Test-Path -LiteralPath $path -PathType Container) {
		[Console]::Error.WriteLine("[ERROR] Expected a JSON file, got a directory: $path")
		exit 1
	}
	$bytes = [System.IO.File]::ReadAllBytes($path)
	if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
		return [System.Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length - 3)
	}
	if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
		return [System.Text.Encoding]::Unicode.GetString($bytes, 2, $bytes.Length - 2)
	}
	if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
		return [System.Text.Encoding]::BigEndianUnicode.GetString($bytes, 2, $bytes.Length - 2)
	}
	try {
		return (New-Object System.Text.UTF8Encoding($false, $true)).GetString($bytes)
	} catch {
		$detail = if ($_.Exception.InnerException) { $_.Exception.InnerException.Message } else { $_.Exception.Message }
		[Console]::Error.WriteLine("[ERROR] ${path} is not valid UTF-8: ${detail} - save the file as UTF-8, or add a BOM if it is UTF-16")
		exit 1
	}
}
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# --- Support guard (Ext/ParentConfigurations.bin) ---
# See docs/1c-support-state-spec.md. Blocks edits of vendor objects "на замке" /
# read-only configs unless allowed. Trigger = bin present; reaction from
# .v8-project.json editingAllowedCheck (deny|warn|off, default deny). Never
# throws — guard errors degrade to allow.
function Get-RootUuid([string]$xmlPath) {
	if (-not (Test-Path $xmlPath)) { return $null }
	try {
		[xml]$mx = Get-Content -Path $xmlPath -Encoding UTF8
		$el = $mx.DocumentElement.FirstChild
		while ($el -and $el.NodeType -ne 'Element') { $el = $el.NextSibling }
		if ($el) { $u = $el.GetAttribute("uuid"); if ($u) { return $u } }
	} catch {}
	return $null
}
function Test-ExternalObjectRoot([string]$xmlPath) {
	if (-not (Test-Path $xmlPath)) { return $false }
	try {
		[xml]$mx = Get-Content -Path $xmlPath -Encoding UTF8
		$el = $mx.DocumentElement.FirstChild
		while ($el -and $el.NodeType -ne 'Element') { $el = $el.NextSibling }
		if ($el) { return @('ExternalDataProcessor','ExternalReport') -contains $el.LocalName }
	} catch {}
	return $false
}
function Find-V8Project([string]$startDir) {
	$d = $startDir
	for ($i = 0; $i -lt 20 -and $d; $i++) {
		$pj = Join-Path $d ".v8-project.json"
		if (Test-Path $pj) { return $pj }
		$parent = [System.IO.Path]::GetDirectoryName($d)
		if ($parent -eq $d) { break }
		$d = $parent
	}
	return $null
}
function Get-EditMode([string]$cfgDir) {
	try {
		$pj = Find-V8Project (Get-Location).Path
		if (-not $pj) { $pj = Find-V8Project $cfgDir }
		if (-not $pj) { return 'deny' }
		$proj = Get-Content -Raw $pj | ConvertFrom-Json
		$cfgFull = [System.IO.Path]::GetFullPath($cfgDir).TrimEnd('\', '/')
		if ($proj.databases) {
			foreach ($db in $proj.databases) {
				if ($db.configSrc) {
					$src = [System.IO.Path]::GetFullPath($db.configSrc).TrimEnd('\', '/')
					if ($cfgFull -eq $src -or $cfgFull.StartsWith($src + [System.IO.Path]::DirectorySeparatorChar)) {
						if ($db.editingAllowedCheck) { return $db.editingAllowedCheck }
					}
				}
			}
		}
		if ($proj.editingAllowedCheck) { return $proj.editingAllowedCheck }
		return 'deny'
	} catch { return 'deny' }
}
function Assert-EditAllowed([string]$targetPath, [string]$require) {
	try {
		$rp = $targetPath
		try { $rp = (Resolve-Path $targetPath -ErrorAction Stop).Path } catch {}
		# Autonomous external object (EPF/ERF): never part of a config on support (issue #39).
		if (Test-ExternalObjectRoot $rp) { return }
		$elemUuid = Get-RootUuid $rp
		$cfgDir = $null; $binPath = $null
		$d = if (Test-Path $rp -PathType Container) { $rp } else { [System.IO.Path]::GetDirectoryName($rp) }
		for ($i = 0; $i -lt 12 -and $d; $i++) {
			if (Test-ExternalObjectRoot "$d.xml") { return }
			if (-not $elemUuid) { $elemUuid = Get-RootUuid "$d.xml" }
			if (-not $cfgDir) {
				$cand = Join-Path (Join-Path $d "Ext") "ParentConfigurations.bin"
				if ((Test-Path $cand) -or (Test-Path (Join-Path $d "Configuration.xml"))) { $cfgDir = $d; $binPath = $cand }
			}
			if ($elemUuid -and $cfgDir) { break }
			$parent = [System.IO.Path]::GetDirectoryName($d)
			if ($parent -eq $d) { break }
			$d = $parent
		}
		# New object (no element file): fall back to config root uuid.
		if (-not $elemUuid -and $cfgDir) { $elemUuid = Get-RootUuid (Join-Path $cfgDir "Configuration.xml") }
		if (-not $binPath -or -not (Test-Path $binPath)) { return }
		$bytes = [System.IO.File]::ReadAllBytes($binPath)
		if ($bytes.Length -le 32) { return }
		$start = 0
		if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { $start = 3 }
		$text = [System.Text.Encoding]::UTF8.GetString($bytes, $start, $bytes.Length - $start)
		$hm = [regex]::Match($text, '^\{6,(\d+),(\d+),')
		if (-not $hm.Success) { return }
		$G = [int]$hm.Groups[1].Value
		$K = [int]$hm.Groups[2].Value
		if ($K -eq 0) { return }
		$best = $null
		if ($elemUuid) {
			$u = [regex]::Escape($elemUuid.ToLower())
			foreach ($m in [regex]::Matches($text, "([0-2]),0,$u")) {
				$f1 = [int]$m.Groups[1].Value
				if ($null -eq $best -or $f1 -lt $best) { $best = $f1 }
			}
		}
		$blocked = $false; $code = ""; $reason = ""
		if ($G -eq 1) { $blocked = $true; $code = "capability-off"; $reason = "возможность изменения конфигурации выключена (вся конфигурация read-only)" }
		elseif ($require -eq 'removed') {
			if ($null -ne $best -and $best -ne 2) { $blocked = $true; $code = "not-removed"; $reason = "объект не снят с поддержки — удаление сломает обновления" }
		}
		else {
			if ($null -ne $best -and $best -eq 0) { $blocked = $true; $code = "locked"; $reason = "объект на замке — редактирование сломает обновления" }
		}
		if (-not $blocked) { return }
		$mode = Get-EditMode $cfgDir
		if ($mode -eq 'off') { return }
		# Use Console.Error (not Write-Error) — under ErrorActionPreference=Stop the
		# latter throws and would be swallowed by this function's own catch.
		if ($mode -eq 'warn') { [Console]::Error.WriteLine("[support-guard] ПРЕДУПРЕЖДЕНИЕ: $reason. Цель: $rp"); return }
		$head = "[support-guard] Редактирование отклонено: это объект типовой конфигурации на поддержке поставщика, прямое редактирование молча сломает будущие обновления."
		$cfe = "Рекомендуемый путь: внести доработку в расширение (навыки cfe-borrow / cfe-patch-method) — состояние поддержки менять не нужно, обновления вендора сохраняются."
		$offNote = "Снять проверку для этой базы: editingAllowedCheck = warn|off в .v8-project.json."
		if ($code -eq "capability-off") {
			$state = "Состояние: у всей конфигурации выключена возможность изменения (режим read-only «из коробки») — поэтому объект «$rp» редактировать нельзя."
			$fix = "Либо снять защиту явно (навык support-edit, два шага):`n  1. support-edit -Path ""$cfgDir"" -Capability on — включить возможность изменения (объекты пока остаются на замке);`n  2. support-edit -Path ""$rp"" -Set editable — открыть этот объект для редактирования.`n  Изменение применяется в базу полной загрузкой выгрузки и обходит механизм обновлений вендора."
		} elseif ($code -eq "not-removed") {
			$state = "Состояние: объект «$rp» на поддержке (не снят с поддержки) — его удаление разорвёт обновления вендора."
			$fix = "Либо сначала снять объект с поддержки, затем удалять:`n  support-edit -Path ""$rp"" -Set off-support — объект уходит из-под обновлений, после этого удаление безопасно."
		} else {
			$state = "Состояние: объект «$rp» на замке (возможность изменения конфигурации включена, но сам объект не редактируется)."
			$fix = "Либо разрешить редактирование этого объекта (навык support-edit, выбрать одно):`n  support-edit -Path ""$rp"" -Set editable — редактировать и дальше получать обновления вендора (возможны конфликты слияния);`n  support-edit -Path ""$rp"" -Set off-support — снять с поддержки: обновления по объекту больше не приходят."
		}
		[Console]::Error.WriteLine("$head`n$state`n$cfe`n$fix`n$offNote")
		exit 1
	} catch { return }
}

# === 1. Load Form.xml ===

if (-not (Test-Path $FormPath)) {
	Write-Error "File not found: $FormPath"
	exit 1
}
if (-not (Test-Path $JsonPath)) {
	Write-Error "File not found: $JsonPath"
	exit 1
}

$resolvedFormPath = (Resolve-Path $FormPath).Path
Assert-EditAllowed $resolvedFormPath 'editable'
$xmlDoc = New-Object System.Xml.XmlDocument
$xmlDoc.PreserveWhitespace = $true
try {
	$xmlDoc.Load($resolvedFormPath)
} catch {
	Write-Host "[ERROR] XML parse error: $($_.Exception.Message)"
	exit 1
}

$formNs = "http://v8.1c.ru/8.3/xcf/logform"
$v8Ns = "http://v8.1c.ru/8.1/data/core"
$nsMgr = New-Object System.Xml.XmlNamespaceManager($xmlDoc.NameTable)
$nsMgr.AddNamespace("f", $formNs)
$nsMgr.AddNamespace("v8", $v8Ns)

$root = $xmlDoc.DocumentElement

# === 2. Load JSON ===

$def = ConvertFrom-JsonInput (Read-JsonInputFile $JsonPath) $JsonPath

# === 3. Form name + header ===

$formName = [System.IO.Path]::GetFileNameWithoutExtension($FormPath)
$parentDir = [System.IO.Path]::GetDirectoryName($resolvedFormPath)
if ($parentDir) {
	$extDir = [System.IO.Path]::GetFileName($parentDir)
	if ($extDir -eq "Ext") {
		$formDir = [System.IO.Path]::GetDirectoryName($parentDir)
		if ($formDir) { $formName = [System.IO.Path]::GetFileName($formDir) }
	}
}

Write-Host "=== form-edit: $formName ==="
Write-Host ""

# === 4. Scan max IDs per pool ===

$script:nextElemId = 0
$script:nextAttrId = 0
$script:nextCmdId = 0

# Scan ALL element IDs via XPath (includes companions like ExtendedTooltip, ContextMenu)
$rootCI = $root.SelectSingleNode("f:ChildItems", $nsMgr)
if ($rootCI) {
	foreach ($elem in $rootCI.SelectNodes(".//*[@id]")) {
		$id = $elem.GetAttribute("id")
		if ($id -and $id -ne "-1") {
			try { $intId = [int]$id; if ($intId -gt $script:nextElemId) { $script:nextElemId = $intId } } catch {}
		}
	}
}
# Командная панель формы: сама (id=-1) и её кнопки — из того же пула, что и элементы
$acb = $root.SelectSingleNode("f:AutoCommandBar", $nsMgr)
if ($acb) {
	$acbIds = New-Object System.Collections.ArrayList
	[void]$acbIds.Add($acb.GetAttribute("id"))
	foreach ($elem in $acb.SelectNodes(".//*[@id]")) { [void]$acbIds.Add($elem.GetAttribute("id")) }
	foreach ($id in $acbIds) {
		if ($id -and $id -ne "-1") {
			try { $intId = [int]$id; if ($intId -gt $script:nextElemId) { $script:nextElemId = $intId } } catch {}
		}
	}
}

# Scan attribute IDs (including column IDs — same pool)
foreach ($attr in $root.SelectNodes("f:Attributes/f:Attribute", $nsMgr)) {
	$id = $attr.GetAttribute("id")
	if ($id) {
		try { $intId = [int]$id; if ($intId -gt $script:nextAttrId) { $script:nextAttrId = $intId } } catch {}
	}
	# Column IDs are in the same pool as attribute IDs
	foreach ($col in $attr.SelectNodes("f:Columns/f:Column", $nsMgr)) {
		$colId = $col.GetAttribute("id")
		if ($colId) {
			try { $intColId = [int]$colId; if ($intColId -gt $script:nextAttrId) { $script:nextAttrId = $intColId } } catch {}
		}
	}
}

# Scan command IDs
foreach ($cmd in $root.SelectNodes("f:Commands/f:Command", $nsMgr)) {
	$id = $cmd.GetAttribute("id")
	if ($id) {
		try { $intId = [int]$id; if ($intId -gt $script:nextCmdId) { $script:nextCmdId = $intId } } catch {}
	}
}

$script:nextElemId++
$script:nextAttrId++
$script:nextCmdId++

# --- 4b. Auto-detect extension mode (BaseForm present) ---
$script:isExtension = $false
$baseForm = $root.SelectSingleNode("f:BaseForm", $nsMgr)
if ($baseForm) {
	$script:isExtension = $true
	if ($script:nextAttrId -lt 1000000) { $script:nextAttrId = 1000000 }
	if ($script:nextCmdId -lt 1000000) { $script:nextCmdId = 1000000 }
	if ($script:nextElemId -lt 1000000) { $script:nextElemId = 1000000 }
}

function New-ElemId { $id = $script:nextElemId; $script:nextElemId++; return $id }
function New-AttrId { $id = $script:nextAttrId; $script:nextAttrId++; return $id }
function New-CmdId { $id = $script:nextCmdId; $script:nextCmdId++; return $id }

# For element emitters, New-Id = New-ElemId
function New-Id { return New-ElemId }

# === 5. Fragment helpers (StringBuilder + Emit-* from form-compile) ===

$script:xml = New-Object System.Text.StringBuilder 4096

function X {
	param([string]$text)
	$script:xml.AppendLine($text) | Out-Null
}

function Esc-Xml {
	param([string]$s)
	# Эскейп ЗНАЧЕНИЯ АТРИБУТА: & < > и кавычка — внутри "..." литеральная " невалидна.
	return $s.Replace('&','&amp;').Replace('<','&lt;').Replace('>','&gt;').Replace('"','&quot;')
}

function Esc-XmlText {
	# Экранирование ТЕКСТА элемента: только & < > . Кавычки в тексте платформа НЕ экранирует —
	# пишет литерально (проверено: 92142 сырых кавычки на корпус, ни одной &quot;). &quot; платформа
	# принимает, но при выгрузке нормализует обратно в кавычку → лишний шум в роундтрипе.
	param([string]$s)
	return $s.Replace('&','&amp;').Replace('<','&lt;').Replace('>','&gt;')
}

function Emit-MLText {
	param([string]$tag, [string]$text, [string]$indent)
	X "$indent<$tag>"
	X "$indent`t<v8:item>"
	X "$indent`t`t<v8:lang>ru</v8:lang>"
	X "$indent`t`t<v8:content>$(Esc-XmlText $text)</v8:content>"
	X "$indent`t</v8:item>"
	X "$indent</$tag>"
}

# --- Type emitter ---

$script:formTypeSynonyms = New-Object System.Collections.Hashtable
$script:formTypeSynonyms["строка"]   = "string"
$script:formTypeSynonyms["число"]    = "decimal"
$script:formTypeSynonyms["булево"]   = "boolean"
$script:formTypeSynonyms["дата"]     = "date"
$script:formTypeSynonyms["датавремя"]= "dateTime"
$script:formTypeSynonyms["number"]   = "decimal"
$script:formTypeSynonyms["bool"]     = "boolean"
$script:formTypeSynonyms["справочникссылка"]            = "CatalogRef"
$script:formTypeSynonyms["справочникобъект"]            = "CatalogObject"
$script:formTypeSynonyms["документссылка"]              = "DocumentRef"
$script:formTypeSynonyms["документобъект"]              = "DocumentObject"
$script:formTypeSynonyms["перечислениессылка"]           = "EnumRef"
$script:formTypeSynonyms["плансчетовссылка"]             = "ChartOfAccountsRef"
$script:formTypeSynonyms["планвидовхарактеристикссылка"] = "ChartOfCharacteristicTypesRef"
$script:formTypeSynonyms["планвидоврасчётассылка"]        = "ChartOfCalculationTypesRef"
$script:formTypeSynonyms["планвидоврасчетассылка"]        = "ChartOfCalculationTypesRef"
$script:formTypeSynonyms["планобменассылка"]              = "ExchangePlanRef"
$script:formTypeSynonyms["бизнеспроцессссылка"]           = "BusinessProcessRef"
$script:formTypeSynonyms["задачассылка"]                  = "TaskRef"
$script:formTypeSynonyms["определяемыйтип"]             = "DefinedType"

# Алиас на локальный словарь: тело Resolve-TypeStr ниже — общая реализация,
# одинаковая во всех навыках (реестр в tests/skills/check-inline-drift.mjs).
$script:typeSynonyms = $script:formTypeSynonyms

function Resolve-TypeStr {
	param([string]$typeStr)
	if (-not $typeStr) { return $typeStr }

	# Прощающий ввод: ведущий префикс приходит копипастой из выгрузки. Без срезания он ломает
	# поиск в словаре — русское имя типа остаётся непереведённым, и платформа отвечает
	# «Неизвестное имя типа». cfg: снимаем всегда — он однозначно означает текущую конфигурацию.
	# Сгенерированный dNpM: (в корпусе на этом URI встречаются d4p1, d5p1, d6p1 — имя префикса
	# платформа выдаёт по порядку объявления) снимаем ТОЛЬКО у ссылочных типов, с точкой:
	# сам по себе префикс многозначен — в формах d5p1:Chart, d5p1:TextDocument,
	# d5p1:GeographicalSchema адресуют чужие пространства имён, и там он часть значения.
	if ($typeStr.StartsWith('cfg:')) {
		$typeStr = $typeStr.Substring(4)
	} elseif ($typeStr.Contains('.') -and $typeStr -match '^d\d+p\d+:') {
		$typeStr = $typeStr.Substring($typeStr.IndexOf(':') + 1)
	}

	# Хвосты, которые дописывает вывод meta-info к множествам типов: суффикс обобщённого метатипа
	# и счётчик состава. Копипаста строки оттуда — обычный путь, поэтому хвост снимаем молча.
	# Срезаем ТОЛЬКО эти известные формы: круглые скобки заняты параметризованными типами
	# (Число(15,2)), слепой срез скобок сломал бы их.
	$typeStr = ($typeStr -replace '\s*\((?:все|all)\)\s*$', '').Trim()
	$typeStr = ($typeStr -replace '\s*[—-]\s*(?:типов|types):\s*\d+\s*$', '').Trim()
	$typeStr = ($typeStr -replace '\s*\((?:типов|types):\s*\d+\)\s*$', '').Trim()

	# Параметризованные типы: Number(15,2), Строка(100)
	if ($typeStr -match '^([^(]+)\((.+)\)$') {
		$baseName = $Matches[1].Trim()
		$params = $Matches[2]
		$resolved = $script:typeSynonyms[$baseName.ToLower()]
		if ($resolved) { return "$resolved($params)" }
		return $typeStr
	}

	# Ссылочные типы: СправочникСсылка.Организации → CatalogRef.Организации
	if ($typeStr.Contains('.')) {
		$dotIdx = $typeStr.IndexOf('.')
		$prefix = $typeStr.Substring(0, $dotIdx)
		$suffix = $typeStr.Substring($dotIdx)  # includes the dot
		$resolved = $script:typeSynonyms[$prefix.ToLower()]
		if ($resolved) { return "$resolved$suffix" }
		return $typeStr
	}

	# Простое имя
	$resolved = $script:typeSynonyms[$typeStr.ToLower()]
	if ($resolved) { return $resolved }
	return $typeStr
}

function Emit-Type {
	param($typeStr, [string]$indent)
	if (-not $typeStr) { X "$indent<Type/>"; return }
	$typeString = "$typeStr"
	$parts = $typeString -split '\s*[|+]\s*'
	X "$indent<Type>"
	foreach ($part in $parts) {
		Emit-SingleType -typeStr $part.Trim() -indent "$indent`t"
	}
	X "$indent</Type>"
}

function Emit-SingleType {
	param([string]$typeStr, [string]$indent)

	$typeStr = Resolve-TypeStr $typeStr

	if ($typeStr -eq "boolean") {
		X "$indent<v8:Type>xs:boolean</v8:Type>"; return
	}
	if ($typeStr -match '^string(\((\d+)\))?$') {
		$len = if ($Matches[2]) { $Matches[2] } else { "0" }
		X "$indent<v8:Type>xs:string</v8:Type>"
		X "$indent<v8:StringQualifiers>"
		X "$indent`t<v8:Length>$len</v8:Length>"
		X "$indent`t<v8:AllowedLength>Variable</v8:AllowedLength>"
		X "$indent</v8:StringQualifiers>"; return
	}
	if ($typeStr -match '^decimal\((\d+),(\d+)(,nonneg)?\)$') {
		$digits = $Matches[1]; $fraction = $Matches[2]
		$sign = if ($Matches[3]) { "Nonnegative" } else { "Any" }
		X "$indent<v8:Type>xs:decimal</v8:Type>"
		X "$indent<v8:NumberQualifiers>"
		X "$indent`t<v8:Digits>$digits</v8:Digits>"
		X "$indent`t<v8:FractionDigits>$fraction</v8:FractionDigits>"
		X "$indent`t<v8:AllowedSign>$sign</v8:AllowedSign>"
		X "$indent</v8:NumberQualifiers>"; return
	}
	if ($typeStr -match '^(date|dateTime|time)$') {
		$fractions = switch ($typeStr) { "date" { "Date" } "dateTime" { "DateTime" } "time" { "Time" } }
		X "$indent<v8:Type>xs:dateTime</v8:Type>"
		X "$indent<v8:DateQualifiers>"
		X "$indent`t<v8:DateFractions>$fractions</v8:DateFractions>"
		X "$indent</v8:DateQualifiers>"; return
	}
	$v8Types = @{
		"ValueTable" = "v8:ValueTable"; "ValueTree" = "v8:ValueTree"; "ValueList" = "v8:ValueListType"
		"TypeDescription" = "v8:TypeDescription"; "Universal" = "v8:Universal"
		"FixedArray" = "v8:FixedArray"; "FixedStructure" = "v8:FixedStructure"
	}
	if ($v8Types.ContainsKey($typeStr)) { X "$indent<v8:Type>$($v8Types[$typeStr])</v8:Type>"; return }
	$uiTypes = @{ "FormattedString" = "v8ui:FormattedString"; "Picture" = "v8ui:Picture"; "Color" = "v8ui:Color"; "Font" = "v8ui:Font" }
	if ($uiTypes.ContainsKey($typeStr)) { X "$indent<v8:Type>$($uiTypes[$typeStr])</v8:Type>"; return }
	if ($typeStr -eq "DynamicList") { X "$indent<v8:Type>cfg:DynamicList</v8:Type>"; return }
	if ($typeStr -match '^DataComposition') {
		$dcsMap = @{ "DataCompositionSettings" = "dcsset:DataCompositionSettings"; "DataCompositionSchema" = "dcssch:DataCompositionSchema"; "DataCompositionComparisonType" = "dcscor:DataCompositionComparisonType" }
		if ($dcsMap.ContainsKey($typeStr)) { X "$indent<v8:Type>$($dcsMap[$typeStr])</v8:Type>"; return }
	}
	if ($typeStr -match '^(CatalogRef|CatalogObject|DocumentRef|DocumentObject|EnumRef|ChartOfAccountsRef|ChartOfCharacteristicTypesRef|ChartOfCalculationTypesRef|ExchangePlanRef|BusinessProcessRef|TaskRef|InformationRegisterRecordSet|AccumulationRegisterRecordSet|DataProcessorObject)\.') {
		X "$indent<v8:Type>cfg:$typeStr</v8:Type>"; return
	}
	if ($typeStr.Contains('.')) { X "$indent<v8:Type>cfg:$typeStr</v8:Type>" }
	else { X "$indent<v8:Type>$typeStr</v8:Type>" }
}

# --- Event handler name generator ---

$script:eventSuffixMap = @{
	"OnChange" = "ПриИзменении"; "StartChoice" = "НачалоВыбора"; "ChoiceProcessing" = "ОбработкаВыбора"
	"AutoComplete" = "АвтоПодбор"; "Clearing" = "Очистка"; "Opening" = "Открытие"; "Click" = "Нажатие"
	"OnActivateRow" = "ПриАктивизацииСтроки"; "BeforeAddRow" = "ПередНачаломДобавления"
	"BeforeDeleteRow" = "ПередУдалением"; "BeforeRowChange" = "ПередНачаломИзменения"
	"OnStartEdit" = "ПриНачалеРедактирования"; "OnEndEdit" = "ПриОкончанииРедактирования"
	"Selection" = "ВыборСтроки"; "OnCurrentPageChange" = "ПриСменеСтраницы"
	"TextEditEnd" = "ОкончаниеВводаТекста"; "URLProcessing" = "ОбработкаНавигационнойСсылки"
	"DragStart" = "НачалоПеретаскивания"; "Drag" = "Перетаскивание"
	"DragCheck" = "ПроверкаПеретаскивания"; "Drop" = "Помещение"; "AfterDeleteRow" = "ПослеУдаления"
}

function Get-HandlerName {
	param([string]$elementName, [string]$eventName)
	$suffix = $script:eventSuffixMap[$eventName]
	if ($suffix) { return "$elementName$suffix" }
	return "$elementName$eventName"
}

# --- Element helpers ---

function Get-ElementName {
	param($el, [string]$typeKey)
	if ($el.name) { return "$($el.name)" }
	return "$($el.$typeKey)"
}

# Уникальность имён внутри JSON-определения (1С: своя коллекция — свой неймспейс).
function Assert-EditUnique {
	param([string]$name, [hashtable]$seen, [string]$ctx)
	if ($seen.ContainsKey($name)) {
		Write-Host "[ERROR] Duplicate $ctx '$name' in JSON definition — names must be unique in 1C form"
		exit 1
	}
	$seen[$name] = $true
}

$script:knownEvents = @{
	"input"     = @("OnChange","StartChoice","ChoiceProcessing","AutoComplete","TextEditEnd","Clearing","Creating","EditTextChange")
	"check"     = @("OnChange")
	"label"     = @("Click","URLProcessing")
	"labelField"= @("OnChange","StartChoice","ChoiceProcessing","Click","URLProcessing","Clearing")
	"table"     = @("Selection","BeforeAddRow","AfterDeleteRow","BeforeDeleteRow","OnActivateRow","OnEditEnd","OnStartEdit","BeforeRowChange","BeforeEditEnd","ValueChoice","OnActivateCell","OnActivateField","Drag","DragStart","DragCheck","DragEnd","OnGetDataAtServer","BeforeLoadUserSettingsAtServer","OnUpdateUserSettingSetAtServer","OnChange")
	"pages"     = @("OnCurrentPageChange")
	"page"      = @("OnCurrentPageChange")
	"button"    = @("Click")
	"picField"  = @("OnChange","StartChoice","ChoiceProcessing","Click","Clearing")
	"calendar"  = @("OnChange","OnActivate")
	"picture"   = @("Click")
	"cmdBar"    = @()
	"popup"     = @()
	"group"     = @()
}

function Emit-Events {
	param($el, [string]$elementName, [string]$indent, [string]$typeKey)
	if (-not $el.on) { return }

	# Validate event names
	if ($typeKey -and $script:knownEvents.ContainsKey($typeKey)) {
		$allowed = $script:knownEvents[$typeKey]
		foreach ($evt in $el.on) {
			$evtStr = if ($evt -is [string]) { "$evt" } else { "$($evt.event)" }
			if ($allowed.Count -gt 0 -and $allowed -notcontains $evtStr) {
				Write-Host "[WARN] Unknown event '$evtStr' for $typeKey '$elementName'. Known: $($allowed -join ', ')"
			}
		}
	}

	X "$indent<Events>"
	foreach ($evt in $el.on) {
		# Support both string ("OnChange") and object ({ "event": "OnChange", "callType": "After" })
		if ($evt -is [string] -or -not $evt.event) {
			$evtName = "$evt"
			$handler = if ($el.handlers -and $el.handlers.$evtName) { "$($el.handlers.$evtName)" }
			else { Get-HandlerName -elementName $elementName -eventName $evtName }
			X "$indent`t<Event name=`"$evtName`">$handler</Event>"
		} else {
			$evtName = "$($evt.event)"
			$handler = if ($evt.handler) { "$($evt.handler)" }
			elseif ($el.handlers -and $el.handlers.$evtName) { "$($el.handlers.$evtName)" }
			else { Get-HandlerName -elementName $elementName -eventName $evtName }
			$callTypeAttr = if ($evt.callType) { " callType=`"$($evt.callType)`"" } else { "" }
			X "$indent`t<Event name=`"$evtName`"$callTypeAttr>$handler</Event>"
		}
	}
	X "$indent</Events>"
}

function Emit-Companion {
	param([string]$tag, [string]$name, [string]$indent)
	$id = New-Id
	X "$indent<$tag name=`"$name`" id=`"$id`"/>"
}

function Emit-CommonFlags {
	param($el, [string]$indent)
	if ($el.visible -eq $false -or $el.hidden -eq $true) { X "$indent<Visible>false</Visible>" }
	if ($el.enabled -eq $false -or $el.disabled -eq $true) { X "$indent<Enabled>false</Enabled>" }
	if ($el.readOnly -eq $true) { X "$indent<ReadOnly>true</ReadOnly>" }
}

function Emit-Title {
	param($el, [string]$name, [string]$indent)
	if ($el.title) { Emit-MLText -tag "Title" -text "$($el.title)" -indent $indent }
}

# --- Element emitters ---

function Emit-Group {
	param($el, [string]$name, [int]$id, [string]$indent)
	X "$indent<UsualGroup name=`"$name`" id=`"$id`">"
	$inner = "$indent`t"
	Emit-Title -el $el -name $name -indent $inner
	$groupVal = "$($el.group)"
	$orientation = switch ($groupVal) {
		"horizontal" { "Horizontal" } "vertical" { "Vertical" }
		"alwaysHorizontal" { "AlwaysHorizontal" } "alwaysVertical" { "AlwaysVertical" }
		default { $null }
	}
	if ($orientation) { X "$inner<Group>$orientation</Group>" }
	if ($groupVal -eq "collapsible") { X "$inner<Group>Vertical</Group>"; X "$inner<Behavior>Collapsible</Behavior>" }
	if ($el.representation) {
		$repr = switch ("$($el.representation)") { "none" { "None" } "normal" { "NormalSeparation" } "weak" { "WeakSeparation" } "strong" { "StrongSeparation" } default { "$($el.representation)" } }
		X "$inner<Representation>$repr</Representation>"
	}
	if ($el.showTitle -eq $false) { X "$inner<ShowTitle>false</ShowTitle>" }
	if ($el.united -eq $false) { X "$inner<United>false</United>" }
	Emit-CommonFlags -el $el -indent $inner
	Emit-Companion -tag "ExtendedTooltip" -name "${name}РасширеннаяПодсказка" -indent $inner
	if ($el.children -and $el.children.Count -gt 0) {
		X "$inner<ChildItems>"
		foreach ($child in $el.children) { Emit-Element -el $child -indent "$inner`t" }
		X "$inner</ChildItems>"
	}
	X "$indent</UsualGroup>"
}

function Emit-Input {
	param($el, [string]$name, [int]$id, [string]$indent)
	X "$indent<InputField name=`"$name`" id=`"$id`">"
	$inner = "$indent`t"
	if ($el.path) { X "$inner<DataPath>$($el.path)</DataPath>" }
	Emit-Title -el $el -name $name -indent $inner
	Emit-CommonFlags -el $el -indent $inner
	if ($el.titleLocation) {
		$loc = switch ("$($el.titleLocation)") { "none" { "None" } "left" { "Left" } "right" { "Right" } "top" { "Top" } "bottom" { "Bottom" } default { "$($el.titleLocation)" } }
		X "$inner<TitleLocation>$loc</TitleLocation>"
	}
	if ($el.multiLine -eq $true) { X "$inner<MultiLine>true</MultiLine>" }
	if ($el.passwordMode -eq $true) { X "$inner<PasswordMode>true</PasswordMode>" }
	if ($el.choiceButton -eq $false) { X "$inner<ChoiceButton>false</ChoiceButton>" }
	if ($el.clearButton -eq $true) { X "$inner<ClearButton>true</ClearButton>" }
	if ($el.spinButton -eq $true) { X "$inner<SpinButton>true</SpinButton>" }
	if ($el.dropListButton -eq $true) { X "$inner<DropListButton>true</DropListButton>" }
	if ($el.markIncomplete -eq $true) { X "$inner<AutoMarkIncomplete>true</AutoMarkIncomplete>" }
	if ($el.skipOnInput -eq $true) { X "$inner<SkipOnInput>true</SkipOnInput>" }
	if ($el.autoMaxWidth -eq $false) { X "$inner<AutoMaxWidth>false</AutoMaxWidth>" }
	if ($el.autoMaxHeight -eq $false) { X "$inner<AutoMaxHeight>false</AutoMaxHeight>" }
	if ($el.width) { X "$inner<Width>$($el.width)</Width>" }
	if ($el.height) { X "$inner<Height>$($el.height)</Height>" }
	if ($el.horizontalStretch -eq $true) { X "$inner<HorizontalStretch>true</HorizontalStretch>" }
	if ($el.verticalStretch -eq $true) { X "$inner<VerticalStretch>true</VerticalStretch>" }
	if ($el.inputHint) { Emit-MLText -tag "InputHint" -text "$($el.inputHint)" -indent $inner }
	Emit-Companion -tag "ContextMenu" -name "${name}КонтекстноеМеню" -indent $inner
	Emit-Companion -tag "ExtendedTooltip" -name "${name}РасширеннаяПодсказка" -indent $inner
	Emit-Events -el $el -elementName $name -indent $inner -typeKey "input"
	X "$indent</InputField>"
}

function Emit-Check {
	param($el, [string]$name, [int]$id, [string]$indent)
	X "$indent<CheckBoxField name=`"$name`" id=`"$id`">"
	$inner = "$indent`t"
	if ($el.path) { X "$inner<DataPath>$($el.path)</DataPath>" }
	Emit-Title -el $el -name $name -indent $inner
	Emit-CommonFlags -el $el -indent $inner
	if ($el.titleLocation) { X "$inner<TitleLocation>$($el.titleLocation)</TitleLocation>" }
	Emit-Companion -tag "ContextMenu" -name "${name}КонтекстноеМеню" -indent $inner
	Emit-Companion -tag "ExtendedTooltip" -name "${name}РасширеннаяПодсказка" -indent $inner
	Emit-Events -el $el -elementName $name -indent $inner -typeKey "check"
	X "$indent</CheckBoxField>"
}

function Emit-Label {
	param($el, [string]$name, [int]$id, [string]$indent)
	X "$indent<LabelDecoration name=`"$name`" id=`"$id`">"
	$inner = "$indent`t"
	if ($el.title) {
		$formatted = if ($el.hyperlink -eq $true) { "true" } else { "false" }
		X "$inner<Title formatted=`"$formatted`">"
		X "$inner`t<v8:item>"
		X "$inner`t`t<v8:lang>ru</v8:lang>"
		X "$inner`t`t<v8:content>$(Esc-XmlText "$($el.title)")</v8:content>"
		X "$inner`t</v8:item>"
		X "$inner</Title>"
	}
	Emit-CommonFlags -el $el -indent $inner
	if ($el.hyperlink -eq $true) { X "$inner<Hyperlink>true</Hyperlink>" }
	if ($el.autoMaxWidth -eq $false) { X "$inner<AutoMaxWidth>false</AutoMaxWidth>" }
	if ($el.autoMaxHeight -eq $false) { X "$inner<AutoMaxHeight>false</AutoMaxHeight>" }
	if ($el.width) { X "$inner<Width>$($el.width)</Width>" }
	if ($el.height) { X "$inner<Height>$($el.height)</Height>" }
	Emit-Companion -tag "ContextMenu" -name "${name}КонтекстноеМеню" -indent $inner
	Emit-Companion -tag "ExtendedTooltip" -name "${name}РасширеннаяПодсказка" -indent $inner
	Emit-Events -el $el -elementName $name -indent $inner -typeKey "label"
	X "$indent</LabelDecoration>"
}

function Emit-LabelField {
	param($el, [string]$name, [int]$id, [string]$indent)
	X "$indent<LabelField name=`"$name`" id=`"$id`">"
	$inner = "$indent`t"
	if ($el.path) { X "$inner<DataPath>$($el.path)</DataPath>" }
	Emit-Title -el $el -name $name -indent $inner
	Emit-CommonFlags -el $el -indent $inner
	if ($el.hyperlink -eq $true) { X "$inner<Hyperlink>true</Hyperlink>" }
	Emit-Companion -tag "ContextMenu" -name "${name}КонтекстноеМеню" -indent $inner
	Emit-Companion -tag "ExtendedTooltip" -name "${name}РасширеннаяПодсказка" -indent $inner
	Emit-Events -el $el -elementName $name -indent $inner -typeKey "labelField"
	X "$indent</LabelField>"
}

function Emit-Table {
	param($el, [string]$name, [int]$id, [string]$indent)
	X "$indent<Table name=`"$name`" id=`"$id`">"
	$inner = "$indent`t"
	if ($el.path) { X "$inner<DataPath>$($el.path)</DataPath>" }
	Emit-Title -el $el -name $name -indent $inner
	Emit-CommonFlags -el $el -indent $inner
	if ($el.representation) { X "$inner<Representation>$($el.representation)</Representation>" }
	if ($el.changeRowSet -eq $true) { X "$inner<ChangeRowSet>true</ChangeRowSet>" }
	if ($el.changeRowOrder -eq $true) { X "$inner<ChangeRowOrder>true</ChangeRowOrder>" }
	if ($el.height) { X "$inner<HeightInTableRows>$($el.height)</HeightInTableRows>" }
	if ($el.header -eq $false) { X "$inner<Header>false</Header>" }
	if ($el.footer -eq $true) { X "$inner<Footer>true</Footer>" }
	if ($el.commandBarLocation) { X "$inner<CommandBarLocation>$($el.commandBarLocation)</CommandBarLocation>" }
	if ($el.searchStringLocation) { X "$inner<SearchStringLocation>$($el.searchStringLocation)</SearchStringLocation>" }
	Emit-Companion -tag "ContextMenu" -name "${name}КонтекстноеМеню" -indent $inner
	Emit-Companion -tag "AutoCommandBar" -name "${name}КоманднаяПанель" -indent $inner
	Emit-Companion -tag "SearchStringAddition" -name "${name}СтрокаПоиска" -indent $inner
	Emit-Companion -tag "ViewStatusAddition" -name "${name}СостояниеПросмотра" -indent $inner
	Emit-Companion -tag "SearchControlAddition" -name "${name}УправлениеПоиском" -indent $inner
	if ($el.columns -and $el.columns.Count -gt 0) {
		X "$inner<ChildItems>"
		foreach ($col in $el.columns) { Emit-Element -el $col -indent "$inner`t" }
		X "$inner</ChildItems>"
	}
	Emit-Events -el $el -elementName $name -indent $inner -typeKey "table"
	X "$indent</Table>"
}

function Emit-Pages {
	param($el, [string]$name, [int]$id, [string]$indent)
	X "$indent<Pages name=`"$name`" id=`"$id`">"
	$inner = "$indent`t"
	if ($el.pagesRepresentation) { X "$inner<PagesRepresentation>$($el.pagesRepresentation)</PagesRepresentation>" }
	Emit-CommonFlags -el $el -indent $inner
	Emit-Companion -tag "ExtendedTooltip" -name "${name}РасширеннаяПодсказка" -indent $inner
	Emit-Events -el $el -elementName $name -indent $inner -typeKey "pages"
	if ($el.children -and $el.children.Count -gt 0) {
		X "$inner<ChildItems>"
		foreach ($child in $el.children) { Emit-Element -el $child -indent "$inner`t" }
		X "$inner</ChildItems>"
	}
	X "$indent</Pages>"
}

function Emit-Page {
	param($el, [string]$name, [int]$id, [string]$indent)
	X "$indent<Page name=`"$name`" id=`"$id`">"
	$inner = "$indent`t"
	Emit-Title -el $el -name $name -indent $inner
	Emit-CommonFlags -el $el -indent $inner
	if ($el.group) {
		$orientation = switch ("$($el.group)") { "horizontal" { "Horizontal" } "vertical" { "Vertical" } "alwaysHorizontal" { "AlwaysHorizontal" } "alwaysVertical" { "AlwaysVertical" } default { $null } }
		if ($orientation) { X "$inner<Group>$orientation</Group>" }
	}
	Emit-Companion -tag "ExtendedTooltip" -name "${name}РасширеннаяПодсказка" -indent $inner
	if ($el.children -and $el.children.Count -gt 0) {
		X "$inner<ChildItems>"
		foreach ($child in $el.children) { Emit-Element -el $child -indent "$inner`t" }
		X "$inner</ChildItems>"
	}
	X "$indent</Page>"
}

function Emit-Button {
	param($el, [string]$name, [int]$id, [string]$indent)
	X "$indent<Button name=`"$name`" id=`"$id`">"
	$inner = "$indent`t"
	if ($el.type) {
		$btnType = switch ("$($el.type)") { "usual" { "UsualButton" } "hyperlink" { "Hyperlink" } "commandBar" { "CommandBarButton" } default { "$($el.type)" } }
		X "$inner<Type>$btnType</Type>"
	}
	if ($el.command) { X "$inner<CommandName>Form.Command.$($el.command)</CommandName>" }
	if ($el.stdCommand) {
		$sc = "$($el.stdCommand)"
		if ($sc -match '^(.+)\.(.+)$') {
			X "$inner<CommandName>Form.Item.$($Matches[1]).StandardCommand.$($Matches[2])</CommandName>"
		} else {
			X "$inner<CommandName>Form.StandardCommand.$sc</CommandName>"
		}
	}
	Emit-Title -el $el -name $name -indent $inner
	Emit-CommonFlags -el $el -indent $inner
	if ($el.defaultButton -eq $true) { X "$inner<DefaultButton>true</DefaultButton>" }
	if ($el.picture) {
		X "$inner<Picture>"
		X "$inner`t<xr:Ref>$($el.picture)</xr:Ref>"
		X "$inner`t<xr:LoadTransparent>true</xr:LoadTransparent>"
		X "$inner</Picture>"
	}
	if ($el.representation) { X "$inner<Representation>$($el.representation)</Representation>" }
	if ($el.locationInCommandBar) { X "$inner<LocationInCommandBar>$($el.locationInCommandBar)</LocationInCommandBar>" }
	Emit-Companion -tag "ExtendedTooltip" -name "${name}РасширеннаяПодсказка" -indent $inner
	Emit-Events -el $el -elementName $name -indent $inner -typeKey "button"
	X "$indent</Button>"
}

function Emit-PictureDecoration {
	param($el, [string]$name, [int]$id, [string]$indent)
	X "$indent<PictureDecoration name=`"$name`" id=`"$id`">"
	$inner = "$indent`t"
	Emit-Title -el $el -name $name -indent $inner
	Emit-CommonFlags -el $el -indent $inner
	if ($el.picture -or $el.src) {
		$ref = if ($el.src) { "$($el.src)" } else { "$($el.picture)" }
		X "$inner<Picture>"; X "$inner`t<xr:Ref>$ref</xr:Ref>"; X "$inner`t<xr:LoadTransparent>true</xr:LoadTransparent>"; X "$inner</Picture>"
	}
	if ($el.hyperlink -eq $true) { X "$inner<Hyperlink>true</Hyperlink>" }
	if ($el.width) { X "$inner<Width>$($el.width)</Width>" }
	if ($el.height) { X "$inner<Height>$($el.height)</Height>" }
	Emit-Companion -tag "ContextMenu" -name "${name}КонтекстноеМеню" -indent $inner
	Emit-Companion -tag "ExtendedTooltip" -name "${name}РасширеннаяПодсказка" -indent $inner
	Emit-Events -el $el -elementName $name -indent $inner -typeKey "picture"
	X "$indent</PictureDecoration>"
}

function Emit-PictureField {
	param($el, [string]$name, [int]$id, [string]$indent)
	X "$indent<PictureField name=`"$name`" id=`"$id`">"
	$inner = "$indent`t"
	if ($el.path) { X "$inner<DataPath>$($el.path)</DataPath>" }
	Emit-Title -el $el -name $name -indent $inner
	Emit-CommonFlags -el $el -indent $inner
	if ($el.width) { X "$inner<Width>$($el.width)</Width>" }
	if ($el.height) { X "$inner<Height>$($el.height)</Height>" }
	Emit-Companion -tag "ContextMenu" -name "${name}КонтекстноеМеню" -indent $inner
	Emit-Companion -tag "ExtendedTooltip" -name "${name}РасширеннаяПодсказка" -indent $inner
	Emit-Events -el $el -elementName $name -indent $inner -typeKey "picField"
	X "$indent</PictureField>"
}

function Emit-Calendar {
	param($el, [string]$name, [int]$id, [string]$indent)
	X "$indent<CalendarField name=`"$name`" id=`"$id`">"
	$inner = "$indent`t"
	if ($el.path) { X "$inner<DataPath>$($el.path)</DataPath>" }
	Emit-Title -el $el -name $name -indent $inner
	Emit-CommonFlags -el $el -indent $inner
	Emit-Companion -tag "ContextMenu" -name "${name}КонтекстноеМеню" -indent $inner
	Emit-Companion -tag "ExtendedTooltip" -name "${name}РасширеннаяПодсказка" -indent $inner
	Emit-Events -el $el -elementName $name -indent $inner -typeKey "calendar"
	X "$indent</CalendarField>"
}

function Emit-CommandBarEl {
	param($el, [string]$name, [int]$id, [string]$indent)
	X "$indent<CommandBar name=`"$name`" id=`"$id`">"
	$inner = "$indent`t"
	if ($el.autofill -eq $true) { X "$inner<Autofill>true</Autofill>" }
	Emit-CommonFlags -el $el -indent $inner
	if ($el.children -and $el.children.Count -gt 0) {
		X "$inner<ChildItems>"
		foreach ($child in $el.children) { Emit-Element -el $child -indent "$inner`t" }
		X "$inner</ChildItems>"
	}
	X "$indent</CommandBar>"
}

function Emit-Popup {
	param($el, [string]$name, [int]$id, [string]$indent)
	X "$indent<Popup name=`"$name`" id=`"$id`">"
	$inner = "$indent`t"
	Emit-Title -el $el -name $name -indent $inner
	Emit-CommonFlags -el $el -indent $inner
	if ($el.picture) {
		X "$inner<Picture>"; X "$inner`t<xr:Ref>$($el.picture)</xr:Ref>"; X "$inner`t<xr:LoadTransparent>true</xr:LoadTransparent>"; X "$inner</Picture>"
	}
	if ($el.representation) { X "$inner<Representation>$($el.representation)</Representation>" }
	if ($el.children -and $el.children.Count -gt 0) {
		X "$inner<ChildItems>"
		foreach ($child in $el.children) { Emit-Element -el $child -indent "$inner`t" }
		X "$inner</ChildItems>"
	}
	X "$indent</Popup>"
}

# --- Element dispatcher ---

function Emit-Element {
	param($el, [string]$indent)

	$typeKey = $null
	foreach ($key in @("group","input","check","label","labelField","table","pages","page","button","picture","picField","calendar","cmdBar","popup")) {
		if ($el.$key -ne $null) { $typeKey = $key; break }
	}
	if (-not $typeKey) { Write-Warning "Unknown element type, skipping"; return }

	# Validate known keys — warn about typos
	$knownKeys = @{
		"group"=1;"input"=1;"check"=1;"label"=1;"labelField"=1;"table"=1;"pages"=1;"page"=1
		"button"=1;"picture"=1;"picField"=1;"calendar"=1;"cmdBar"=1;"popup"=1
		"name"=1;"path"=1;"title"=1
		"visible"=1;"hidden"=1;"enabled"=1;"disabled"=1;"readOnly"=1
		"on"=1;"handlers"=1
		"titleLocation"=1;"representation"=1;"width"=1;"height"=1
		"horizontalStretch"=1;"verticalStretch"=1;"autoMaxWidth"=1;"autoMaxHeight"=1
		"multiLine"=1;"passwordMode"=1;"choiceButton"=1;"clearButton"=1
		"spinButton"=1;"dropListButton"=1;"markIncomplete"=1;"skipOnInput"=1;"inputHint"=1
		"hyperlink"=1;"showTitle"=1;"united"=1;"children"=1;"columns"=1
		"changeRowSet"=1;"changeRowOrder"=1;"header"=1;"footer"=1
		"commandBarLocation"=1;"searchStringLocation"=1;"pagesRepresentation"=1
		"type"=1;"command"=1;"stdCommand"=1;"defaultButton"=1;"locationInCommandBar"=1
		"src"=1;"autofill"=1
		"into"=1;"after"=1;"before"=1;"first"=1
	}
	foreach ($p in $el.PSObject.Properties) {
		if (-not $knownKeys.ContainsKey($p.Name)) {
			Write-Warning "Element '$($el.$typeKey)': unknown key '$($p.Name)' — ignored."
		}
	}

	$name = Get-ElementName -el $el -typeKey $typeKey
	$id = New-Id

	switch ($typeKey) {
		"group"     { Emit-Group -el $el -name $name -id $id -indent $indent }
		"input"     { Emit-Input -el $el -name $name -id $id -indent $indent }
		"check"     { Emit-Check -el $el -name $name -id $id -indent $indent }
		"label"     { Emit-Label -el $el -name $name -id $id -indent $indent }
		"labelField" { Emit-LabelField -el $el -name $name -id $id -indent $indent }
		"table"     { Emit-Table -el $el -name $name -id $id -indent $indent }
		"pages"     { Emit-Pages -el $el -name $name -id $id -indent $indent }
		"page"      { Emit-Page -el $el -name $name -id $id -indent $indent }
		"button"    { Emit-Button -el $el -name $name -id $id -indent $indent }
		"picture"   { Emit-PictureDecoration -el $el -name $name -id $id -indent $indent }
		"picField"  { Emit-PictureField -el $el -name $name -id $id -indent $indent }
		"calendar"  { Emit-Calendar -el $el -name $name -id $id -indent $indent }
		"cmdBar"    { Emit-CommandBarEl -el $el -name $name -id $id -indent $indent }
		"popup"     { Emit-Popup -el $el -name $name -id $id -indent $indent }
	}
}

# === 6. Find element by name recursively ===

function Find-Element($startNode, [string]$targetName) {
	foreach ($child in $startNode.ChildNodes) {
		if ($child.NodeType -ne 'Element') { continue }
		$childName = $child.GetAttribute("name")
		if ($childName -eq $targetName) { return $child }
		$ci = $child.SelectSingleNode("f:ChildItems", $nsMgr)
		if ($ci) {
			$found = Find-Element $ci $targetName
			if ($found) { return $found }
		}
	}
	return $null
}

# === 7. Detect indent level of a container's children ===

function Get-ChildIndent($container) {
	foreach ($child in $container.ChildNodes) {
		if ($child.NodeType -eq 'Whitespace' -or $child.NodeType -eq 'SignificantWhitespace') {
			$text = $child.Value
			if ($text -match '^\r?\n(\t+)$') { return $Matches[1] }
			if ($text -match '^\r?\n(\t+)') { return $Matches[1] }
		}
	}
	# Fallback: count depth from root
	$depth = 0
	$current = $container
	while ($current -and $current -ne $xmlDoc.DocumentElement) {
		$depth++
		$current = $current.ParentNode
	}
	return "`t" * ($depth + 1)
}

# === 8. Insert node into container ===

function Insert-IntoContainer($container, $newNode, $afterName, $childIndent) {
	$refNode = $null

	if ($afterName) {
		# Find the after-element, then insert after it
		$afterElem = $null
		foreach ($child in $container.ChildNodes) {
			if ($child.NodeType -eq 'Element' -and $child.GetAttribute("name") -eq $afterName) {
				$afterElem = $child
				break
			}
		}
		if ($afterElem) {
			$refNode = $afterElem.NextSibling
		} else {
			Write-Host "[WARN] after='$afterName' not found in target container, appending at end"
		}
	}

	if (-not $refNode) {
		# Append at end: insert before trailing whitespace
		$trailing = $container.LastChild
		if ($trailing -and ($trailing.NodeType -eq 'Whitespace' -or $trailing.NodeType -eq 'SignificantWhitespace')) {
			$refNode = $trailing
		}
	}

	$ws = $xmlDoc.CreateWhitespace("`r`n$childIndent")
	if ($refNode) {
		$container.InsertBefore($ws, $refNode) | Out-Null
		$container.InsertBefore($newNode, $refNode) | Out-Null
	} else {
		# Container is empty (self-closing) — add framing whitespace
		$container.AppendChild($ws) | Out-Null
		$container.AppendChild($newNode) | Out-Null
		$parentIndent = if ($childIndent.Length -gt 1) { $childIndent.Substring(0, $childIndent.Length - 1) } else { "" }
		$closeWs = $xmlDoc.CreateWhitespace("`r`n$parentIndent")
		$container.AppendChild($closeWs) | Out-Null
	}
}

# === 9. Generate fragment, parse, import nodes ===

$allNsDecl = 'xmlns="http://v8.1c.ru/8.3/xcf/logform" xmlns:v8="http://v8.1c.ru/8.1/data/core" xmlns:v8ui="http://v8.1c.ru/8.1/data/ui" xmlns:xr="http://v8.1c.ru/8.3/xcf/readable" xmlns:xs="http://www.w3.org/2001/XMLSchema" xmlns:cfg="http://v8.1c.ru/8.1/data/enterprise/current-config" xmlns:dcsset="http://v8.1c.ru/8.1/data-composition-system/settings" xmlns:dcscor="http://v8.1c.ru/8.1/data-composition-system/core" xmlns:dcssch="http://v8.1c.ru/8.1/data-composition-system/schema"'

function Parse-Fragment([string]$xmlText) {
	$fragDoc = New-Object System.Xml.XmlDocument
	$fragDoc.PreserveWhitespace = $true
	$fragDoc.LoadXml($xmlText)
	return $fragDoc
}

function Import-ElementNodes($fragDoc) {
	$nodes = @()
	foreach ($child in $fragDoc.DocumentElement.ChildNodes) {
		if ($child.NodeType -eq 'Element') {
			$nodes += $xmlDoc.ImportNode($child, $true)
		}
	}
	return $nodes
}

# === 9b. Канонический порядок дочерних тегов элемента ===
# В каком порядке платформа пишет свойства и вложенные узлы элемента формы. Построено по корпусу
# выгрузок (БП и ERP, 8.3.24, 17036 форм): для каждого типа элемента — граф «тег A раньше тега B»,
# противоречий нет. По нему новое свойство (set), новый ChildItems или Events встают туда, где их
# пишет платформа, — иначе первая же выгрузка из базы переставит их обратно.
$script:childTagOrder = @{
	'AutoCommandBar' = 'HorizontalAlign Autofill ChildItems'
	'Button' = 'Type Visible TitleHeight UserVisible Representation DefaultButton SkipOnInput Enabled DefaultItem Width AutoMaxWidth MaxWidth Height AutoMaxHeight HorizontalStretch MaxHeight VerticalStretch GroupHorizontalAlign Check GroupVerticalAlign CommandName Parameter DataPath TextColor BackColor BorderColor Font Picture Title Shape ToolTipRepresentation RepresentationInContextMenu ShapeRepresentation PictureLocation LocationInCommandBar CommandUniqueness ExtendedTooltip'
	'ButtonGroup' = 'EnableContentChange Visible Title GroupVerticalAlign ToolTip HorizontalStretch GroupHorizontalAlign ToolTipRepresentation CommandSource Representation VerticalStretch ExtendedTooltip ChildItems'
	'CalendarField' = 'DataPath SkipOnInput Title TitleLocation ToolTip ToolTipRepresentation Width AutoMaxWidth Height HorizontalStretch SelectionMode ShowCurrentDate ShowMonthsPanel WidthInMonths HeightInMonths ContextMenu ExtendedTooltip Events'
	'ChartField' = 'DataPath Enabled Title TitleFont Visible TitleLocation GroupHorizontalAlign Width AutoMaxWidth MaxHeight MaxWidth Height AutoMaxHeight HorizontalStretch VerticalStretch ContextMenu ExtendedTooltip Events'
	'CheckBoxField' = 'DataPath Visible Enabled UserVisible DefaultItem ReadOnly SkipOnInput Title TitleTextColor TitleFont TitleLocation TitleHeight ToolTip FooterHorizontalAlign HorizontalAlign ToolTipRepresentation Shortcut GroupHorizontalAlign VerticalAlign GroupVerticalAlign WarningOnEditRepresentation WarningOnEdit EditMode AutoCellHeight CellHyperlink FixingInTable ShowInHeader FooterDataPath HeaderPicture HeaderHorizontalAlign ShowInFooter CheckBoxType EditFormat ItemHeight ItemTitleHeight ItemWidth EqualItemsWidth ThreeState ContextMenu ExtendedTooltip Events'
	'ColumnGroup' = 'Visible Enabled ReadOnly UserVisible EnableContentChange Title GroupVerticalAlign TitleFont TitleTextColor ToolTip ToolTipRepresentation Width Height HorizontalStretch GroupHorizontalAlign VerticalStretch Group ShowTitle ShowInHeader HeaderDataPath HeaderHorizontalAlign HeaderFormat HeaderPicture FixingInTable ExtendedTooltip ChildItems'
	'CommandBar' = 'Enabled Visible EnableContentChange Title ToolTip ToolTipRepresentation Width Height HorizontalStretch VerticalStretch GroupHorizontalAlign GroupVerticalAlign HorizontalLocation CommandSource ExtendedTooltip ChildItems'
	'FormattedDocumentField' = 'DataPath DefaultItem Enabled ReadOnly SkipOnInput Title TitleLocation CommandSet Font ToolTip EditMode Width AutoMaxWidth Height AutoMaxHeight BorderColor HorizontalStretch MaxWidth ContextMenu ExtendedTooltip Events'
	'GanttChartField' = 'DataPath DefaultItem TitleLocation Width Height HorizontalStretch VerticalStretch ContextMenu ExtendedTooltip Table Events'
	'GraphicalSchemaField' = 'DataPath DefaultItem ReadOnly Title TitleLocation WarningOnEditRepresentation Width Height Edit ContextMenu ExtendedTooltip Events'
	'HTMLDocumentField' = 'DataPath DefaultItem Enabled ReadOnly SkipOnInput Title TitleTextColor TitleFont TitleLocation ToolTipRepresentation Visible WarningOnEditRepresentation Width AutoMaxWidth MaxWidth Height AutoMaxHeight MaxHeight HorizontalStretch VerticalStretch Output BorderColor ContextMenu ExtendedTooltip Events'
	'InputField' = 'DataPath Visible UserVisible DefaultItem Enabled ReadOnly SkipOnInput Title TitleBackColor TitleTextColor TitleFont TitleLocation TitleHeight ToolTip ToolTipRepresentation WarningOnEditRepresentation WarningOnEdit Shortcut HorizontalAlign VerticalAlign GroupHorizontalAlign GroupVerticalAlign EditMode CellHyperlink FixingInTable AutoCellHeight ShowInHeader HeaderHorizontalAlign HeaderPicture ShowInFooter FooterDataPath FooterText FooterTextColor FooterFont FooterHorizontalAlign FooterPicture Width AutoMaxWidth MaxWidth Height AutoMaxHeight MaxHeight HorizontalStretch AllowInputEmptyMultipleValues MultipleValuesFont MultipleValuesTextColor MultipleValuesBackColor VerticalStretch Wrap MarkNegatives PasswordMode MultiLine ExtendedEdit DropListButton ChoiceButton ChoiceButtonRepresentation ClearButton SpinButton OpenButton CreateButton Mask ListChoiceMode ExtendedEditMultipleValues AutoChoiceIncomplete Format MultipleValuePictureShape QuickChoice ChoiceFoldersAndItems EditFormat AutoMarkIncomplete ChooseType AutoShowOpenButtonMode IncompleteChoiceMode ShowCheckBoxesInDropList MultipleValueDataPath MultipleValuePictureDataPath MultipleValuePresentDataPath SpellCheckingOnTextInput TypeDomainEnabled TextEdit AvailableTypes ChoiceForm ChoiceParameterLinks ChoiceParameters EditTextUpdate MinValue ChoiceButtonPicture MaxValue ChoiceList AutoCorrectionOnTextInput AutoShowClearButtonMode ChoiceListButton ChoiceListHeight DropListWidth TextColor BackColor BorderColor Font HeightControlVariant SpecialTextInputMode InputHint ChoiceHistoryOnInput TypeLink ContextMenu ExtendedTooltip Events'
	'LabelDecoration' = 'UserVisible Visible Enabled Width AutoMaxWidth MaxWidth Height AutoMaxHeight MaxHeight HorizontalStretch VerticalStretch SkipOnInput TextColor Font Shortcut Title ToolTip ToolTipRepresentation GroupHorizontalAlign GroupVerticalAlign Hyperlink HorizontalAlign VerticalAlign BackColor BorderColor Border TitleHeight ContextMenu ExtendedTooltip Events'
	'LabelField' = 'DataPath Visible Enabled UserVisible DefaultItem ReadOnly SkipOnInput Title TitleTextColor TitleFont TitleLocation TitleHeight ToolTip ToolTipRepresentation HorizontalAlign VerticalAlign GroupHorizontalAlign GroupVerticalAlign WarningOnEditRepresentation WarningOnEdit EditMode FixingInTable CellHyperlink AutoCellHeight FooterText ShowInHeader HeaderHorizontalAlign FooterDataPath HeaderPicture ShowInFooter FooterHorizontalAlign Width AutoMaxWidth MaxWidth Height AutoMaxHeight MaxHeight HorizontalStretch MarkNegatives VerticalStretch Format Border BorderColor Hiperlink PasswordMode TextColor BackColor Font ContextMenu ExtendedTooltip Events'
	'Page' = 'Visible Enabled ReadOnly EnableContentChange UserVisible Title GroupVerticalAlign Shortcut TitleTextColor TitleFont ToolTip ToolTipRepresentation Width Height HorizontalStretch VerticalStretch ChildrenAlign Picture Format Group ChildItemsWidth HorizontalSpacing VerticalSpacing HorizontalAlign VerticalAlign ShowTitle BackColor TitleDataPath ScrollOnCompress ExtendedTooltip ChildItems'
	'Pages' = 'Enabled ReadOnly EnableContentChange UserVisible Visible Title TitleFont ToolTip ToolTipRepresentation Width Height HorizontalStretch VerticalStretch GroupHorizontalAlign GroupVerticalAlign PagesRepresentation CurrentRowUse ExtendedTooltip Events ChildItems'
	'PeriodField' = 'DataPath TitleLocation ContextMenu ExtendedTooltip'
	'PictureDecoration' = 'Enabled Visible Width AutoMaxWidth MaxWidth Height AutoMaxHeight MaxHeight HorizontalStretch VerticalStretch SkipOnInput TextColor Font Title ToolTip ToolTipRepresentation GroupHorizontalAlign GroupVerticalAlign Hyperlink PictureSize Zoomable ImageScale NonselectedPictureText EnableStartDrag EnableDrag Picture BorderColor Border FileDragMode ContextMenu ExtendedTooltip Events'
	'PictureField' = 'DataPath TitleBackColor UserVisible Visible Enabled ReadOnly SkipOnInput Title TitleTextColor TitleLocation TitleHeight ToolTip GroupHorizontalAlign GroupVerticalAlign Shortcut ToolTipRepresentation HorizontalAlign WarningOnEditRepresentation EditMode AutoCellHeight FixingInTable CellHyperlink ShowInHeader FooterDataPath HeaderPicture FooterText HeaderHorizontalAlign ShowInFooter FooterHorizontalAlign Width AutoMaxWidth MaxWidth Height AutoMaxHeight MaxHeight HorizontalStretch VerticalStretch PictureSize Zoomable Hyperlink NonselectedPictureText EnableDrag TextColor ValuesPicture BorderColor Border Font FileDragMode ContextMenu ExtendedTooltip Events'
	'PlannerField' = 'DataPath TitleLocation ContextMenu ExtendedTooltip Events'
	'Popup' = 'UserVisible Visible EnableContentChange Title Shape TitleTextColor TitleFont ToolTip ToolTipRepresentation VerticalStretch Width HorizontalStretch Picture CommandSource Representation BackColor ShapeRepresentation BorderColor ExtendedTooltip ChildItems'
	'ProgressBarField' = 'DataPath Title Visible ReadOnly TitleLocation ToolTip ToolTipRepresentation Width AutoMaxHeight AutoMaxWidth HorizontalStretch MaxValue ShowPercent ContextMenu ExtendedTooltip'
	'RadioButtonField' = 'DataPath DefaultItem Enabled SkipOnInput UserVisible Visible ReadOnly Title TitleTextColor TitleFont TitleLocation FooterHorizontalAlign TitleHeight ToolTip ToolTipRepresentation EditMode GroupHorizontalAlign Shortcut VerticalAlign GroupVerticalAlign WarningOnEditRepresentation WarningOnEdit RadioButtonType ItemHeight ItemTitleHeight ItemWidth ColumnsCount EqualColumnsWidth ChoiceList Font TextColor ContextMenu ExtendedTooltip Events'
	'SpreadSheetDocumentField' = 'DataPath Enabled ReadOnly SkipOnInput UserVisible Visible DefaultItem Title TitleLocation DrawingSelectionShowMode FooterHorizontalAlign GroupHorizontalAlign ToolTip ToolTipRepresentation CommandSet Width AutoMaxWidth MaxWidth Height AutoMaxHeight MaxHeight HorizontalStretch VerticalStretch ShowGrid ShowHeaders VerticalScrollBar HorizontalScrollBar Protection SelectionShowMode Edit Output PointerType ShowGroups EnableStartDrag EnableDrag BorderColor ShowCellNames ShowRowAndColumnNames ViewScalingMode ContextMenu ExtendedTooltip Events'
	'Table' = 'Representation Visible UserVisible TitleLocation CommandBarLocation Autofill Enabled TitleHeight ReadOnly SkipOnInput DefaultItem ChangeRowSet ChangeRowOrder Width AutoMaxWidth MaxWidth Height AutoMaxHeight MaxHeight HeightInTableRows HeightControlVariant AutoMaxRowsCount MaxRowsCount ChoiceMode MultipleChoice RowInputMode SelectionMode RowSelectionMode Header FooterHeight HeaderHeight Footer HorizontalScrollBar VerticalScrollBar HorizontalLines VerticalLines UseAlternationRowColor AutoInsertNewRow AutoAddIncomplete AutoMarkIncomplete SearchOnInput InitialListView InitialTreeView HorizontalStretch Output VerticalStretch EnableStartDrag EnableDrag FileDragMode DataPath Font RowPictureDataPath RowsPicture BackColor BorderColor TextColor Title BehaviorOnHorizontalCompression GroupVerticalAlign Shortcut TitleTextColor TitleFont CommandSet ToolTip ToolTipRepresentation SearchStringLocation ViewStatusLocation SearchControlLocation GroupHorizontalAlign CurrentRowUse RefreshRequest AutoRefresh AutoRefreshPeriod Period ChoiceFoldersAndItems RestoreCurrentRow RowFilter TopLevelParent ShowRoot AllowRootChoice UpdateOnDataChange UserSettingsGroup AllowGettingCurrentRowURL ViewMode SettingsNamedItemDetailedRepresentation ContextMenu AutoCommandBar ExtendedTooltip SearchStringAddition ViewStatusAddition SearchControlAddition Events ChildItems'
	'TextDocumentField' = 'DataPath DefaultItem ReadOnly Title TitleFont TitleLocation EditMode ToolTip Width AutoMaxWidth Font MaxWidth Height AutoMaxHeight ContextMenu ExtendedTooltip Events'
	'TrackBarField' = 'DataPath Title TitleLocation HorizontalAlign ToolTip ToolTipRepresentation Width AutoMaxWidth HorizontalStretch MaxWidth Height AutoMaxHeight MinValue MarkingAppearance MaxValue LargeStep Step MarkingStep ContextMenu ExtendedTooltip Events'
	'UsualGroup' = 'UserVisible Visible Enabled ReadOnly EnableContentChange Title TitleTextColor TitleFont ToolTip ToolTipRepresentation Shortcut Width Height HorizontalStretch VerticalStretch GroupHorizontalAlign GroupVerticalAlign Group ChildrenAlign HorizontalSpacing VerticalSpacing HorizontalAlign VerticalAlign Behavior CollapsedRepresentationTitle Collapsed ControlRepresentation Representation CurrentRowUse Format ShowLeftMargin United ChildItemsWidth ShowTitle BackColor ThroughAlign TitleDataPath ExtendedTooltip ChildItems'
}
$script:childRank = @{}
foreach ($t in $script:childTagOrder.Keys) {
	$idx = @{}; $i = 0
	foreach ($c in ($script:childTagOrder[$t] -split ' ')) { $idx[$c] = $i; $i++ }
	$script:childRank[$t] = $idx
}

function Get-ChildRank([string]$parentTag, [string]$childTag) {
	$idx = $script:childRank[$parentTag]
	if ($idx -and $idx.ContainsKey($childTag)) { return $idx[$childTag] }
	return -1
}

# === 9c. Помощники операций над деревом элементов ===

function Fail([string]$msg) {
	Write-Host "[ERROR] $msg"
	exit 1
}

function Same($a, $b) { return [object]::ReferenceEquals($a, $b) }

function Test-IsWs($n) {
	return ($null -ne $n -and ($n.NodeType -eq 'Whitespace' -or $n.NodeType -eq 'SignificantWhitespace'))
}

function Get-NextElementSibling($n) {
	$s = $n.NextSibling
	while ($null -ne $s -and $s.NodeType -ne 'Element') { $s = $s.NextSibling }
	return $s
}

function Get-FirstElementChild($n) {
	foreach ($c in $n.ChildNodes) { if ($c.NodeType -eq 'Element') { return $c } }
	return $null
}

function Get-ContainerLabel($c) {
	if (Same $c $root) { return "корень формы" }
	return $c.GetAttribute("name")
}

# Вставка узла в контейнер: перед $ref или в конец. Перевод строки с отступом идёт перед каждым
# дочерним узлом, у пустого контейнера — ещё и закрывающий с отступом родителя.
function Insert-NodeAt($container, $node, $ref, [string]$indent) {
	if ($null -ne $ref) {
		$container.InsertBefore($node, $ref) | Out-Null
		$container.InsertBefore($xmlDoc.CreateWhitespace("`r`n$indent"), $ref) | Out-Null
		return
	}
	$trailing = $container.LastChild
	if (Test-IsWs $trailing) {
		$container.InsertBefore($xmlDoc.CreateWhitespace("`r`n$indent"), $trailing) | Out-Null
		$container.InsertBefore($node, $trailing) | Out-Null
	} else {
		$container.AppendChild($xmlDoc.CreateWhitespace("`r`n$indent")) | Out-Null
		$container.AppendChild($node) | Out-Null
		$parentIndent = if ($indent.Length -gt 0) { $indent.Substring(0, $indent.Length - 1) } else { "" }
		$container.AppendChild($xmlDoc.CreateWhitespace("`r`n$parentIndent")) | Out-Null
	}
}

# Дочерний узел элемента — на его каноническое место (см. 9b). Неизвестный тег — в конец.
function Insert-ChildCanonical($parent, $child) {
	$rank = Get-ChildRank $parent.LocalName $child.LocalName
	$ref = $null
	if ($rank -ge 0) {
		foreach ($c in $parent.ChildNodes) {
			if ($c.NodeType -ne 'Element') { continue }
			if ((Get-ChildRank $parent.LocalName $c.LocalName) -gt $rank) { $ref = $c; break }
		}
	}
	Insert-NodeAt $parent $child $ref (Get-ChildIndent $parent)
}

# Узел вместе с переводом строки перед ним.
function Remove-NodeWithWs($node) {
	$parent = $node.ParentNode
	$prev = $node.PreviousSibling
	if (Test-IsWs $prev) { $parent.RemoveChild($prev) | Out-Null }
	$parent.RemoveChild($node) | Out-Null
}

# Пустой ChildItems платформа не пишет никогда: у группы без элементов тега просто нет.
function Remove-IfEmptyChildItems($ci) {
	if ($null -ne (Get-FirstElementChild $ci)) { return }
	Remove-NodeWithWs $ci
	if (Same $ci $script:rootCI) { $script:rootCI = $null }
}

$script:rootAfterChildItems = @('Attributes','Parameters','Commands','CommandInterface','ConditionalAppearance','BaseForm')

function Get-OrCreateChildItems($container) {
	$ci = $container.SelectSingleNode("f:ChildItems", $nsMgr)
	if ($null -ne $ci) { return $ci }
	$ci = $xmlDoc.CreateElement("ChildItems", $formNs)
	if (Same $container $root) {
		# ChildItems формы — после Events или AutoCommandBar, иначе перед первой из следующих секций
		$insertAfter = $root.SelectSingleNode("f:Events", $nsMgr)
		if ($null -eq $insertAfter) { $insertAfter = $root.SelectSingleNode("f:AutoCommandBar", $nsMgr) }
		$ref = $null
		if ($null -ne $insertAfter) {
			$ref = Get-NextElementSibling $insertAfter
		} else {
			foreach ($c in $root.ChildNodes) {
				if ($c.NodeType -eq 'Element' -and $script:rootAfterChildItems -contains $c.LocalName) { $ref = $c; break }
			}
		}
		Insert-NodeAt $root $ci $ref "`t"
		$script:rootCI = $ci
	} else {
		Insert-ChildCanonical $container $ci
	}
	return $ci
}

function Get-NodeIndent($node) {
	$prev = $node.PreviousSibling
	if ((Test-IsWs $prev) -and $prev.Value -match '\n(\t*)$') { return $Matches[1] }
	return ""
}

# Сдвиг отступов поддерева при смене глубины: каждый перевод строки внутри узла начинается с отступа
# старого места — меняем этот префикс на новый.
function Set-SubtreeIndent($node, [string]$oldIndent, [string]$newIndent) {
	if ($oldIndent -eq $newIndent) { return }
	foreach ($c in $node.ChildNodes) {
		if (Test-IsWs $c) {
			if ($c.Value -match '^(\r?\n)(\t*)$' -and $Matches[2].StartsWith($oldIndent)) {
				$c.Value = $Matches[1] + $newIndent + $Matches[2].Substring($oldIndent.Length)
			}
		} elseif ($c.NodeType -eq 'Element') {
			Set-SubtreeIndent $c $oldIndent $newIndent
		}
	}
}

# Элемент формы по имени: дерево ChildItems и командная панель формы (с кнопками). BaseForm,
# реквизиты и команды не просматриваются. Имена в 1С регистронезависимы.
function Find-FormElement([string]$name) {
	$scopes = @()
	if ($null -ne $script:rootCI) { $scopes += $script:rootCI }
	$acb = $root.SelectSingleNode("f:AutoCommandBar", $nsMgr)
	if ($null -ne $acb) {
		if ($acb.GetAttribute("name") -eq $name) { return $acb }
		$scopes += $acb
	}
	# Элементы — узлы ChildItems и служебные узлы элемента (для внятного отказа); <Event name=…> и
	# прочие именованные свойства — не элементы.
	foreach ($s in $scopes) {
		foreach ($n in $s.SelectNodes(".//*[@name]")) {
			if ($n.NamespaceURI -ne $formNs -or $n.GetAttribute("name") -ne $name) { continue }
			if ($n.ParentNode.LocalName -eq 'ChildItems' -or $script:companionTags -contains $n.LocalName) { return $n }
		}
	}
	return $null
}

function Get-NearestTable($node, [bool]$inclusive) {
	$cur = if ($inclusive) { $node } else { $node.ParentNode }
	while ($null -ne $cur -and $cur.NodeType -eq 'Element') {
		if ($cur.LocalName -eq 'Table') { return $cur }
		$cur = $cur.ParentNode
	}
	return $null
}

function Test-IsInside($node, $anc) {
	$cur = $node
	while ($null -ne $cur -and $cur.NodeType -eq 'Element') {
		if (Same $cur $anc) { return $true }
		$cur = $cur.ParentNode
	}
	return $false
}

# Позиция операции: контейнер + узел, перед которым вставлять ($null — в конец).
# after/before — контейнер якоря; into — в конец (first — в начало); first без into — начало формы.
function Resolve-Position($op, [string]$ctx, [bool]$required) {
	$after = $op.after; $before = $op.before; $into = $op.into
	if ($null -ne $op.PSObject.Properties['first'] -and -not ($op.first -is [bool])) { Fail "${ctx}: first — true или false" }
	$first = ($op.first -is [bool] -and $op.first)
	if ($after -and $before) { Fail "${ctx}: укажи что-то одно — after или before" }
	$anchorName = if ($after) { "$after" } elseif ($before) { "$before" } else { $null }
	if ($first -and $anchorName) { Fail "${ctx}: first — это начало контейнера, вместе с after/before не задаётся" }
	$intoEl = $null
	if ($into) {
		$intoEl = Find-FormElement "$into"
		if ($null -eq $intoEl) { Fail "${ctx}: контейнер '$into' не найден в форме" }
	}
	if ($anchorName) {
		$anchor = Find-FormElement $anchorName
		if ($null -eq $anchor) { Fail "${ctx}: элемент '$anchorName' не найден в форме" }
		$ci = $anchor.ParentNode
		if ($ci.LocalName -ne 'ChildItems') { Fail "${ctx}: '$anchorName' — служебный узел ($($anchor.LocalName)), рядом с ним ставить нельзя" }
		$container = $ci.ParentNode
		if ($null -ne $intoEl -and -not (Same $intoEl $container)) {
			Fail "${ctx}: '$anchorName' лежит в '$(Get-ContainerLabel $container)', а не в '$into'"
		}
		if ($after) {
			return @{ Container = $container; Ref = (Get-NextElementSibling $anchor); Anchor = $anchor; Desc = "$(Get-ContainerLabel $container), после $anchorName" }
		}
		return @{ Container = $container; Ref = $anchor; Anchor = $anchor; Desc = "$(Get-ContainerLabel $container), перед $anchorName" }
	}
	if ($null -eq $intoEl -and $first) { $intoEl = $root }
	if ($null -ne $intoEl) {
		$ref = $null
		if ($first) {
			$ci = $intoEl.SelectSingleNode("f:ChildItems", $nsMgr)
			if ($null -ne $ci) { $ref = Get-FirstElementChild $ci }
		}
		$where = if ($first) { "первым" } else { "в конец" }
		return @{ Container = $intoEl; Ref = $ref; Anchor = $null; Desc = "$(Get-ContainerLabel $intoEl), $where" }
	}
	if ($required) { Fail "${ctx}: не указано, куда — нужен after, before или into" }
	return $null
}

$script:containerTags = @('UsualGroup','Page','Pages','Table','ColumnGroup','CommandBar','AutoCommandBar','ButtonGroup','Popup','ContextMenu')
$script:barTags = @('CommandBar','AutoCommandBar','ButtonGroup','Popup','ContextMenu')
$script:barItemTags = @('Button','ButtonGroup','Popup')
$script:tableItemTags = @('InputField','CheckBoxField','LabelField','PictureField','ColumnGroup')
$script:companionTags = @('ContextMenu','ExtendedTooltip','AutoCommandBar','SearchStringAddition','ViewStatusAddition','SearchControlAddition')
$script:dslTagMap = @{
	"group"="UsualGroup"; "input"="InputField"; "check"="CheckBoxField"; "label"="LabelDecoration"
	"labelField"="LabelField"; "table"="Table"; "pages"="Pages"; "page"="Page"; "button"="Button"
	"picture"="PictureDecoration"; "picField"="PictureField"; "calendar"="CalendarField"; "cmdBar"="CommandBar"; "popup"="Popup"
}

# Может ли элемент типа $nt лечь в $container. $node — переносимый узел (у добавления $null).
function Assert-Placement([string]$nt, [string]$name, $node, $container, [string]$ctx) {
	$isRoot = Same $container $root
	$ct = if ($isRoot) { "Form" } else { $container.LocalName }
	$cl = Get-ContainerLabel $container
	if (-not $isRoot -and $script:containerTags -notcontains $ct) { Fail "${ctx}: '$cl' ($ct) не контейнер — в него нельзя положить элемент" }
	if ($null -ne $node -and (Test-IsInside $container $node)) { Fail "${ctx}: '$name' нельзя перенести внутрь самого себя — '$cl' лежит внутри '$name'" }
	if ($nt -eq 'Page' -and $ct -ne 'Pages') { Fail "${ctx}: страница '$name' может лежать только в группе страниц (Pages), а '$cl' — $ct" }
	if ($ct -eq 'Pages' -and $nt -ne 'Page') { Fail "${ctx}: в группе страниц '$cl' лежат только страницы (Page), а '$name' — $nt" }
	if ($script:barTags -contains $ct -and $script:barItemTags -notcontains $nt) { Fail "${ctx}: в командной панели '$cl' лежат только кнопки, группы кнопок и подменю, а '$name' — $nt" }
	# Группа кнопок и подменю — только внутри командной панели, меню, подменю или группы кнопок (по корпусу)
	if (@('ButtonGroup','Popup') -contains $nt -and $script:barTags -notcontains $ct) { Fail "${ctx}: '$name' ($nt) лежит только в командной панели, контекстном меню, подменю или группе кнопок, а '$cl' — $ct" }
	if ($nt -eq 'ColumnGroup' -and $null -eq (Get-NearestTable $container $true)) { Fail "${ctx}: группа колонок '$name' может лежать только внутри таблицы" }
	# Колонки таблицы — только поля и группы колонок (по корпусу других типов там нет);
	# командная панель и контекстное меню таблицы — свои правила выше.
	$inTable = if ($isRoot) { $null } else { Get-NearestTable $container $true }
	if ($null -ne $inTable -and $script:barTags -notcontains $ct -and $script:tableItemTags -notcontains $nt) {
		Fail "${ctx}: в таблице '$($inTable.GetAttribute('name'))' лежат только колонки (поля и группы колонок), а '$name' — $nt"
	}
	# Граница таблицы: колонки и поля табличной части привязаны к своей таблице. Кнопки — нет
	# (стандартная команда таблицы законно стоит и в командной панели формы).
	if ($null -ne $node -and $script:barItemTags -notcontains $nt) {
		$from = Get-NearestTable $node $false
		$to = if ($isRoot) { $null } else { Get-NearestTable $container $true }
		if (-not (Same $from $to)) {
			if ($null -ne $from) { Fail "${ctx}: '$name' принадлежит таблице '$($from.GetAttribute('name'))' — вынести его за её пределы или в другую таблицу нельзя" }
			Fail "${ctx}: '$name' не принадлежит таблице — внутрь таблицы '$($to.GetAttribute('name'))' его перенести нельзя"
		}
	}
}

function Assert-OpKeys($op, [string[]]$allowed, [string]$ctx) {
	foreach ($p in $op.PSObject.Properties) {
		if ($allowed -notcontains $p.Name) { Fail "${ctx}: неизвестный ключ '$($p.Name)'; допустимы: $($allowed -join ', ')" }
	}
}

# --- Добавление ---

$script:chainNode = $null
$script:defaultPos = $null

function Invoke-Add($op, [string]$typeKey, [int]$idx) {
	$name = Get-ElementName -el $op -typeKey $typeKey
	$ctx = "elements[$idx] $typeKey '$name'"
	# Имя уже есть в форме — на момент этой операции (удалённое раньше в списке — свободно)
	$existing = Find-FormElement $name
	if ($null -ne $existing) {
		Write-Host "[ERROR] Element '$name' already exists in form (id=$($existing.GetAttribute('id'))) — element names must be unique"
		exit 1
	}
	$pos = Resolve-Position $op $ctx $false
	if ($null -eq $pos) {
		# Без своей позиции — как раньше: верхние into/after, следующие встают за предыдущим.
		if ($null -ne $script:chainNode) {
			$c = $script:chainNode.ParentNode.ParentNode
			$pos = @{ Container = $c; Ref = (Get-NextElementSibling $script:chainNode); Anchor = $null; Desc = "$(Get-ContainerLabel $c), после $($script:chainNode.GetAttribute('name'))" }
		} else {
			if ($null -eq $script:defaultPos) {
				$script:defaultPos = Resolve-Position $def "elements (верхние into/after)" $false
				if ($null -eq $script:defaultPos) { $script:defaultPos = @{ Container = $root; Ref = $null; Anchor = $null; Desc = "корень формы, в конец" } }
			}
			$pos = $script:defaultPos
		}
		$chained = $true
	} else {
		$chained = $false
	}
	Assert-Placement $script:dslTagMap[$typeKey] $name $null $pos.Container $ctx

	$ci = Get-OrCreateChildItems $pos.Container
	$indent = Get-ChildIndent $ci
	$script:xml = New-Object System.Text.StringBuilder 4096
	X "<_F $allNsDecl>"
	Emit-Element -el $op -indent $indent
	X "</_F>"
	$node = @(Import-ElementNodes (Parse-Fragment $script:xml.ToString()))[0]
	Insert-NodeAt $ci $node $pos.Ref $indent
	if ($chained) { $script:chainNode = $node }

	$pathStr = if ($op.path) { " -> $($op.path)" } else { "" }
	$evtStr = if ($op.on) { " {$((@($op.on) | ForEach-Object { if ($_ -is [string]) { $_ } else { $_.event } }) -join ', ')}" } else { "" }
	$script:opLog += "  + [$($node.LocalName)] $name$pathStr$evtStr → $($pos.Desc)"
	$script:addedCount++
}

# --- Перенос ---

function Invoke-Move($op, [int]$idx) {
	$ctx = "elements[$idx] move"
	Assert-OpKeys $op @('move','after','before','into','first') $ctx
	$names = @(@($op.move) | ForEach-Object { "$_" } | Where-Object { $_ })
	if ($names.Count -eq 0) { Fail "${ctx}: укажи имя элемента или список имён" }
	$nodes = @()
	$seen = @{}
	foreach ($n in $names) {
		if ($seen.ContainsKey($n)) { Fail "${ctx}: '$n' указан дважды" }
		$seen[$n] = $true
		$node = Find-FormElement $n
		if ($null -eq $node) { Fail "${ctx}: элемент '$n' не найден в форме" }
		if ($node.ParentNode.LocalName -ne 'ChildItems' -or $script:companionTags -contains $node.LocalName) {
			Fail "${ctx}: '$n' — служебный узел ($($node.LocalName)) своего элемента, переносится только вместе с ним"
		}
		$nodes += $node
	}
	$pos = Resolve-Position $op $ctx $true
	foreach ($node in $nodes) {
		if (Same $node $pos.Anchor) { Fail "${ctx}: '$($node.GetAttribute('name'))' не может быть якорем собственного переноса" }
		Assert-Placement $node.LocalName $node.GetAttribute('name') $node $pos.Container $ctx
	}

	$ref = $pos.Ref
	$desc = $pos.Desc
	$prev = $null
	foreach ($node in $nodes) {
		$name = $node.GetAttribute('name')
		if ($null -ne $prev) {
			$ref = Get-NextElementSibling $prev
			$desc = "$(Get-ContainerLabel $pos.Container), после $($prev.GetAttribute('name'))"
		}
		$fromCI = $node.ParentNode
		$targetCI = $pos.Container.SelectSingleNode("f:ChildItems", $nsMgr)
		if ((Same $fromCI $targetCI) -and ((Same $ref $node) -or (Same $ref (Get-NextElementSibling $node)))) {
			$script:opLog += "  = ${name}: уже на месте ($desc)"
			$prev = $node
			continue
		}
		$fromLabel = Get-ContainerLabel $fromCI.ParentNode
		# Отступ цели — до отцепления: если узел был в ней единственным, после отцепления
		# первым пробельным узлом окажется закрывающий с отступом родителя.
		$newIndent = if ($null -ne $targetCI) { Get-ChildIndent $targetCI } else { $null }
		$oldIndent = Get-NodeIndent $node
		Remove-NodeWithWs $node
		$ci = Get-OrCreateChildItems $pos.Container
		if ($null -eq $newIndent) { $newIndent = Get-ChildIndent $ci }
		Insert-NodeAt $ci $node $ref $newIndent
		Set-SubtreeIndent $node $oldIndent $newIndent
		if (-not (Same $fromCI $ci)) { Remove-IfEmptyChildItems $fromCI }
		$script:opLog += "  ~ ${name}: $fromLabel → $desc"
		$script:movedCount++
		$prev = $node
	}
}

# --- Изменение свойств ---

# Умолчания платформы: в корпусе эти теги встречаются только с противоположным значением —
# значение по умолчанию платформа не пишет, и set его не пишет, а убирает тег.
$script:tagDefaults = @{
	'Visible'='true'; 'Enabled'='true'; 'ReadOnly'='false'; 'ShowTitle'='true'; 'United'='true'; 'Collapsed'='false'
	'AutoMaxWidth'='true'; 'AutoMaxHeight'='true'; 'Hyperlink'='false'; 'Hiperlink'='false'
}
# Умолчания перечислений зависят от типа элемента: значение из области, которого в корпусе нет ни
# разу у этого типа (у таблицы TitleLocation=Auto пишется явно — там правило не действует).
$script:enumDefaults = @{
	'UsualGroup/Group'='HorizontalIfPossible'; 'Page/Group'='Vertical'; 'ColumnGroup/Group'='Vertical'
	'UsualGroup/Representation'='WeakSeparation'; 'Button/Representation'='Auto'; 'Popup/Representation'='Auto'
}

function Get-TagDefault([string]$nt, [string]$tag) {
	if ($script:tagDefaults.ContainsKey($tag)) { return $script:tagDefaults[$tag] }
	if ($script:enumDefaults.ContainsKey("$nt/$tag")) { return $script:enumDefaults["$nt/$tag"] }
	if ($tag -eq 'TitleLocation' -and $nt -ne 'Table') { return 'Auto' }
	return $null
}

# Значение по умолчанию платформа не пишет — и set его не пишет, а убирает тег.
function Set-ValueTag($node, [string]$tag, [string]$text) {
	if ((Get-TagDefault $node.LocalName $tag) -ceq $text) {
		$existing = $node.SelectSingleNode("f:$tag", $nsMgr)
		if ($null -ne $existing) { Remove-NodeWithWs $existing }
		return
	}
	Set-SimpleTag $node $tag $text
}

$script:titleLocMap = @{ 'none'='None'; 'left'='Left'; 'right'='Right'; 'top'='Top'; 'bottom'='Bottom'; 'auto'='Auto' }
# Ключи — словарь form-compile; Tags — кандидаты по типу элемента (у LabelField платформа пишет Hiperlink).
$script:setProps = [ordered]@{
	'title'=@{ Tags=@('Title'); Kind='ml' }
	'tooltip'=@{ Tags=@('ToolTip'); Kind='ml' }
	'inputHint'=@{ Tags=@('InputHint'); Kind='ml' }
	'visible'=@{ Tags=@('Visible'); Kind='bool' }
	'hidden'=@{ Tags=@('Visible'); Kind='bool'; Invert=$true }
	'enabled'=@{ Tags=@('Enabled'); Kind='bool' }
	'disabled'=@{ Tags=@('Enabled'); Kind='bool'; Invert=$true }
	'readOnly'=@{ Tags=@('ReadOnly'); Kind='bool' }
	'skipOnInput'=@{ Tags=@('SkipOnInput'); Kind='bool' }
	'titleLocation'=@{ Tags=@('TitleLocation'); Kind='enum'; Map=$script:titleLocMap }
	'width'=@{ Tags=@('Width'); Kind='num' }
	'height'=@{ Tags=@('HeightInTableRows','Height'); Kind='num' }
	'maxWidth'=@{ Tags=@('MaxWidth'); Kind='num' }
	'maxHeight'=@{ Tags=@('MaxHeight'); Kind='num' }
	'autoMaxWidth'=@{ Tags=@('AutoMaxWidth'); Kind='bool' }
	'autoMaxHeight'=@{ Tags=@('AutoMaxHeight'); Kind='bool' }
	'horizontalStretch'=@{ Tags=@('HorizontalStretch'); Kind='bool' }
	'verticalStretch'=@{ Tags=@('VerticalStretch'); Kind='bool' }
	'multiLine'=@{ Tags=@('MultiLine'); Kind='bool' }
	'passwordMode'=@{ Tags=@('PasswordMode'); Kind='bool' }
	'choiceButton'=@{ Tags=@('ChoiceButton'); Kind='bool' }
	'clearButton'=@{ Tags=@('ClearButton'); Kind='bool' }
	'spinButton'=@{ Tags=@('SpinButton'); Kind='bool' }
	'dropListButton'=@{ Tags=@('DropListButton'); Kind='bool' }
	'markIncomplete'=@{ Tags=@('AutoMarkIncomplete'); Kind='bool' }
	'hyperlink'=@{ Tags=@('Hyperlink','Hiperlink'); Kind='bool' }
	'group'=@{ Tags=@('Group'); Kind='enum'; Map=@{ 'vertical'='Vertical'; 'horizontal'='Horizontal'; 'horizontalifpossible'='HorizontalIfPossible'; 'alwayshorizontal'='AlwaysHorizontal'; 'alwaysvertical'='AlwaysVertical'; 'incell'='InCell' } }
	'behavior'=@{ Tags=@('Behavior'); Kind='enum'; Map=@{ 'usual'='Usual'; 'collapsible'='Collapsible'; 'popup'='PopUp' } }
	'collapsed'=@{ Tags=@('Collapsed'); Kind='bool' }
	'representation'=@{ Tags=@('Representation'); Kind='repr' }
	'showTitle'=@{ Tags=@('ShowTitle'); Kind='bool' }
	'united'=@{ Tags=@('United'); Kind='bool' }
}
# Значения Representation — свои у каждого типа (по корпусу); ключи — как в form-compile.
$script:reprMaps = @{
	'UsualGroup' = @{ 'none'='None'; 'normal'='NormalSeparation'; 'weak'='WeakSeparation'; 'strong'='StrongSeparation' }
	'Table' = @{ 'list'='List'; 'tree'='Tree'; 'hierarchicallist'='HierarchicalList' }
	'Button' = @{ 'auto'='Auto'; 'text'='Text'; 'picture'='Picture'; 'pictureandtext'='PictureAndText' }
	'Popup' = @{ 'auto'='Auto'; 'text'='Text'; 'picture'='Picture'; 'pictureandtext'='PictureAndText' }
	'ButtonGroup' = @{ 'usual'='Usual'; 'compact'='Compact' }
}
$script:xmlTagToDsl = @{}
foreach ($k in $script:dslTagMap.Keys) { $script:xmlTagToDsl[$script:dslTagMap[$k]] = $k }

function Get-PropTag($spec, [string]$nt) {
	foreach ($t in $spec.Tags) { if ((Get-ChildRank $nt $t) -ge 0) { return $t } }
	return $null
}

function Get-ApplicableSetKeys([string]$nt) {
	$keys = @()
	foreach ($k in $script:setProps.Keys) {
		if ($k -in @('hidden','disabled')) { continue }
		if ($null -ne (Get-PropTag $script:setProps[$k] $nt)) { $keys += $k }
	}
	if ((Get-ChildRank $nt 'Events') -ge 0) { $keys += 'on' }
	return $keys
}

function Set-SimpleTag($node, [string]$tag, [string]$text) {
	$existing = $node.SelectSingleNode("f:$tag", $nsMgr)
	if ($null -ne $existing) { $existing.InnerText = $text; return }
	$el = $xmlDoc.CreateElement($tag, $formNs)
	$el.InnerText = $text
	Insert-ChildCanonical $node $el
}

function Set-MLTag($node, [string]$tag, $value) {
	$indent = Get-ChildIndent $node
	$script:xml = New-Object System.Text.StringBuilder 512
	X "<_F $allNsDecl>"
	X "$indent<$tag>"
	if ($value -is [string]) {
		# Строка меняет только русский текст: переводы на другие языки остаются как были
		$items = @()
		$prevEl = $node.SelectSingleNode("f:$tag", $nsMgr)
		$hasRu = $false
		if ($null -ne $prevEl) {
			foreach ($it in $prevEl.SelectNodes("v8:item", $nsMgr)) {
				$lang = $it.SelectSingleNode("v8:lang", $nsMgr).InnerText
				if ($lang -eq 'ru') { $items += @{ Lang = 'ru'; Text = $value }; $hasRu = $true }
				else { $items += @{ Lang = $lang; Text = $it.SelectSingleNode("v8:content", $nsMgr).InnerText } }
			}
		}
		if (-not $hasRu) { $items = @(@{ Lang = 'ru'; Text = $value }) + $items }
	} else {
		$items = @($value.PSObject.Properties | ForEach-Object { @{ Lang = $_.Name; Text = "$($_.Value)" } })
	}
	foreach ($it in $items) {
		X "$indent`t<v8:item>"
		X "$indent`t`t<v8:lang>$($it.Lang)</v8:lang>"
		X "$indent`t`t<v8:content>$(Esc-XmlText $it.Text)</v8:content>"
		X "$indent`t</v8:item>"
	}
	X "$indent</$tag>"
	X "</_F>"
	$newEl = @(Import-ElementNodes (Parse-Fragment $script:xml.ToString()))[0]
	$existing = $node.SelectSingleNode("f:$tag", $nsMgr)
	if ($null -ne $existing) {
		# Атрибуты узла (formatted у заголовка надписи) переживают замену текста
		foreach ($a in @($existing.Attributes)) { $newEl.SetAttribute($a.LocalName, $a.Value) }
		$node.ReplaceChild($newEl, $existing) | Out-Null
		return
	}
	if ($tag -eq 'Title' -and $node.LocalName -eq 'LabelDecoration') { $newEl.SetAttribute('formatted', 'false') }
	Insert-ChildCanonical $node $newEl
}

function Add-ElementEvents($node, $on, $handlers, [string]$ctx) {
	$nt = $node.LocalName
	$name = $node.GetAttribute('name')
	if ((Get-ChildRank $nt 'Events') -lt 0) { Fail "${ctx}: у $nt '$name' событий нет" }
	$dsl = $script:xmlTagToDsl[$nt]
	$allowed = if ($dsl -and $script:knownEvents.ContainsKey($dsl)) { $script:knownEvents[$dsl] } else { @() }
	$events = $node.SelectSingleNode("f:Events", $nsMgr)
	foreach ($evt in @($on)) {
		if ($evt -is [string] -or -not $evt.event) {
			$evtName = "$evt"; $callType = ""
			$handler = if ($handlers -and $handlers.$evtName) { "$($handlers.$evtName)" } else { Get-HandlerName -elementName $name -eventName $evtName }
		} else {
			$evtName = "$($evt.event)"; $callType = if ($evt.callType) { "$($evt.callType)" } else { "" }
			$handler = if ($evt.handler) { "$($evt.handler)" } elseif ($handlers -and $handlers.$evtName) { "$($handlers.$evtName)" } else { Get-HandlerName -elementName $name -eventName $evtName }
		}
		# Заимствованный элемент в расширении: событие без callType платформа читает как Before и так и пишет
		if (-not $callType -and $script:isExtension -and (Test-Borrowed $name 'element')) { $callType = 'Before' }
		if ($allowed.Count -gt 0 -and $allowed -notcontains $evtName) {
			Write-Host "[WARN] Unknown event '$evtName' for $dsl '$name'. Known: $($allowed -join ', ')"
		}
		$ctStr = if ($callType) { "[$callType]" } else { "" }
		if ($null -ne $events) {
			$dup = $null
			foreach ($e in $events.SelectNodes("f:Event", $nsMgr)) {
				if ($e.GetAttribute('name') -eq $evtName -and $e.GetAttribute('callType') -eq $callType) { $dup = $e; break }
			}
			if ($null -ne $dup) {
				if ($dup.InnerText -eq $handler) { $script:opLog += "  = ${name}: событие $evtName$ctStr -> $handler уже есть"; continue }
				Fail "${ctx}: у '$name' событие $evtName$ctStr уже обрабатывает '$($dup.InnerText)' — второй обработчик не повесить"
			}
		}
		if ($null -eq $events) {
			$events = $xmlDoc.CreateElement("Events", $formNs)
			Insert-ChildCanonical $node $events
		}
		$ev = $xmlDoc.CreateElement("Event", $formNs)
		$ev.SetAttribute('name', $evtName)
		if ($callType) { $ev.SetAttribute('callType', $callType) }
		$ev.InnerText = $handler
		Insert-NodeAt $events $ev $null (Get-ChildIndent $events)
		$script:opLog += "  * ${name}: событие $evtName$ctStr -> $handler"
	}
}

function Invoke-Set($op, [int]$idx) {
	$ctx = "elements[$idx] set"
	$names = @(@($op.set) | ForEach-Object { "$_" } | Where-Object { $_ })
	if ($names.Count -eq 0) { Fail "${ctx}: укажи имя элемента или список имён" }
	$props = @($op.PSObject.Properties | Where-Object { $_.Name -ne 'set' })
	if ($props.Count -eq 0) { Fail "${ctx}: не указано, что менять" }
	$forbidden = @('name','path','children','columns')
	foreach ($n in $names) {
		$node = Find-FormElement $n
		if ($null -eq $node) { Fail "${ctx}: элемент '$n' не найден в форме" }
		$nt = $node.LocalName
		$c = "$ctx '$n'"
		foreach ($p in $props) {
			$key = $p.Name
			if ($key -eq 'handlers') { if (-not $op.on) { Fail "${c}: handlers задаются вместе с on" }; continue }
			if ($key -eq 'on') { Add-ElementEvents $node $p.Value $op.handlers $c; continue }
			if ($forbidden -contains $key -or ($script:dslTagMap.ContainsKey($key) -and $key -ne 'group')) {
				Fail "${c}: '$key' через set не меняется (имя и привязку не трогаем — на них ссылаются модуль и расширения; состав — через move)"
			}
			if (-not $script:setProps.Contains($key)) {
				Fail "${c}: неизвестное свойство '$key'; у $nt доступно: $((Get-ApplicableSetKeys $nt) -join ', ')"
			}
			$spec = $script:setProps[$key]
			$tag = Get-PropTag $spec $nt
			if ($null -eq $tag) { Fail "${c}: свойство '$key' к $nt не применимо; доступно: $((Get-ApplicableSetKeys $nt) -join ', ')" }
			$v = $p.Value
			if ($null -eq $v) {
				$existing = $node.SelectSingleNode("f:$tag", $nsMgr)
				if ($null -ne $existing) { Remove-NodeWithWs $existing }
				$script:opLog += "  * ${n}: $key сброшено"
				$script:changedCount++
				continue
			}
			switch ($spec.Kind) {
				'ml' {
					$mlOk = ($v -is [string]) -or (($v -is [System.Management.Automation.PSCustomObject]) -and @($v.PSObject.Properties).Count -gt 0 -and -not (@($v.PSObject.Properties) | Where-Object { -not ($_.Value -is [string]) }))
					if (-not $mlOk) { Fail "${c}: $key — строка или объект {ru, en, ...} со строковыми значениями" }
					Set-MLTag $node $tag $v
					$shown = if ($v -is [string]) { $v } else { ($v.PSObject.Properties | ForEach-Object { "$($_.Name):$($_.Value)" }) -join ' ' }
					$script:opLog += "  * ${n}: $key=`"$shown`""
				}
				'bool' {
					if (-not ($v -is [bool])) { Fail "${c}: $key — true или false" }
					if ($spec.Invert) { $v = -not $v }
					$text = if ($v) { 'true' } else { 'false' }
					Set-ValueTag $node $tag $text
					$script:opLog += "  * ${n}: $tag=$text"
				}
				'num' {
					if (-not ($v -is [int] -or $v -is [long]) -or $v -lt 0) { Fail "${c}: $key — целое неотрицательное число" }
					Set-SimpleTag $node $tag "$v"
					$script:opLog += "  * ${n}: $tag=$v"
				}
				'enum' {
					$mapped = $spec.Map["$v".ToLower()]
					if (-not $mapped) { Fail "${c}: $key='$v' — допустимо: $(($spec.Map.Keys | Sort-Object) -join ', ')" }
					Set-ValueTag $node $tag $mapped
					$script:opLog += "  * ${n}: $tag=$mapped"
				}
				'repr' {
					$rmap = $script:reprMaps[$nt]
					if ($null -eq $rmap) { Fail "${c}: свойство '$key' к $nt не применимо; доступно: $((Get-ApplicableSetKeys $nt) -join ', ')" }
					$text = $rmap["$v".ToLower()]
					if (-not $text) { Fail "${c}: representation='$v' — допустимо: $(($rmap.Keys | Sort-Object) -join ', ')" }
					Set-ValueTag $node $tag $text
					$script:opLog += "  * ${n}: $tag=$text"
				}
			}
			$script:changedCount++
		}
	}
}

# --- Удаление ---

$dcsSetNs = "http://v8.1c.ru/8.1/data-composition-system/settings"
$nsMgr.AddNamespace("dcsset", $dcsSetNs)
$script:removeLog = @()
$script:removedCount = 0
$script:leftHandlers = @()
$script:moduleScan = $null

# Модуль формы — рядом с Form.xml: <...>/Ext/Form/Module.bsl. Сканер BSL: строковые литералы (с "" и
# многострочными продолжениями «|») и комментарии // отделяются от кода, номера строк сохраняются.
function Get-ModuleScan {
	if ($null -ne $script:moduleScan) { return $script:moduleScan }
	$scan = @{ Exists = $false; Raw = ""; Lines = @(); Code = @(); Literals = @() }
	$path = Join-Path ([System.IO.Path]::GetDirectoryName($resolvedFormPath)) "Form/Module.bsl"
	if (Test-Path -LiteralPath $path) {
		$scan.Exists = $true
		$scan.Raw = [System.IO.File]::ReadAllText($path)
		$lines = $scan.Raw -replace "`r", "" -split "`n"
		$code = New-Object System.Collections.ArrayList
		$lits = New-Object System.Collections.ArrayList
		$inStr = $false; $cur = $null; $curLine = 0; $curPrefix = ""
		for ($i = 0; $i -lt $lines.Count; $i++) {
			$line = $lines[$i]
			$sb = New-Object System.Text.StringBuilder
			$j = 0
			if ($inStr) {
				# продолжение многострочного литерала: пробелы, затем «|»
				while ($j -lt $line.Length -and ($line[$j] -eq ' ' -or $line[$j] -eq "`t")) { $j++ }
				if ($j -lt $line.Length -and $line[$j] -eq '|') { $j++ }
				$cur += "`n"
			}
			while ($j -lt $line.Length) {
				$c = $line[$j]
				if ($inStr) {
					if ($c -eq '"') {
						if ($j + 1 -lt $line.Length -and $line[$j + 1] -eq '"') { $cur += '"'; $j += 2; continue }
						$inStr = $false
						[void]$lits.Add(@{ Line = $curLine; Text = $cur; Prefix = $curPrefix })
						[void]$sb.Append('""')
						$j++
						continue
					}
					$cur += $c; $j++; continue
				}
				if ($c -eq '/' -and $j + 1 -lt $line.Length -and $line[$j + 1] -eq '/') { break }
				if ($c -eq '"') { $inStr = $true; $cur = ""; $curLine = $i + 1; $curPrefix = $sb.ToString(); $j++; continue }
				[void]$sb.Append($c); $j++
			}
			[void]$code.Add($sb.ToString())
		}
		$scan.Lines = $lines
		$scan.Code = $code.ToArray()
		$scan.Literals = $lits.ToArray()
	}
	$script:moduleScan = $scan
	return $scan
}

# Где имя элемента/команды передают строкой: Найти("X"), ПолеКомпоновкиДанных("X"), ПутьКДанным = "X",
# УстановитьСвойствоЭлементаФормы(Элементы, "X", …); реквизита — ещё РеквизитФормыВЗначение("X") и
# ЗначениеВРеквизитФормы(…, "X").
$script:itemLiteralContext = '((?<!\w)(Найти|Find|ПолеКомпоновкиДанных|DataCompositionField)\s*\(\s*|(?<!\w)(ПутьКДанным|DataPath)\s*=\s*|(?<!\w)(Элементы|Items)\s*,\s*)$'
$script:attrLiteralContext = '((?<!\w)(ПолеКомпоновкиДанных|DataCompositionField|РеквизитФормыВЗначение|FormAttributeToValue)\s*\(\s*|(?<!\w)(ЗначениеВРеквизитФормы|ValueToFormAttribute)\s*\(.*,\s*|(?<!\w)(ПутьКДанным|DataPath)\s*=\s*)$'

# Номера строк модуля, где есть ссылка на имя. Kind: element | command | attribute.
function Find-ModuleRefs([string]$name, [string]$kind) {
	$scan = Get-ModuleScan
	$hits = New-Object System.Collections.Generic.SortedSet[int]
	if (-not $scan.Exists) { return @() }
	$n = [regex]::Escape($name)
	$opt = [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
	for ($i = 0; $i -lt $scan.Code.Count; $i++) {
		$code = $scan.Code[$i]
		if ($kind -eq 'element') {
			if ([regex]::IsMatch($code, "(?<!\w)(Элементы|Items|ПодчиненныеЭлементы|ChildItems)\s*\.\s*$n(?!\w)", $opt)) { [void]$hits.Add($i + 1) }
		} elseif ($kind -eq 'command') {
			if ([regex]::IsMatch($code, "(?<!\w)(Команды|Commands)\s*\.\s*$n(?!\w)", $opt)) { [void]$hits.Add($i + 1) }
		} else {
			# Реквизит формы: имя целым словом не после точки; после точки — только ЭтаФорма./ЭтотОбъект.
			foreach ($m in [regex]::Matches($code, "(?<!\w)$n(?!\w)", $opt)) {
				$before = $code.Substring(0, $m.Index)
				if ($before -match '\.\s*$') {
					if ([regex]::IsMatch($before, '(?<![\w.])(ЭтаФорма|ЭтотОбъект|ThisForm|ThisObject)\s*\.\s*$', $opt)) { [void]$hits.Add($i + 1) }
				} else {
					[void]$hits.Add($i + 1)
				}
			}
		}
	}
	# Строкой имя передают только в узком наборе вызовов (по корпусу) — остальные литералы
	# (параметры запроса, ключи структур) с именем совпадают случайно и ссылкой не считаются.
	$ctxPat = if ($kind -eq 'attribute') { $script:attrLiteralContext } else { $script:itemLiteralContext }
	foreach ($lit in $scan.Literals) {
		$t = $lit.Text
		$match = ($t -eq $name -or ($kind -eq 'attribute' -and $t.StartsWith("$name.", [System.StringComparison]::OrdinalIgnoreCase)))
		if ($match -and [regex]::IsMatch($lit.Prefix, $ctxPat, $opt)) { [void]$hits.Add($lit.Line) }
	}
	return @($hits)
}

function Format-ModuleRefs([int[]]$lines) {
	$scan = Get-ModuleScan
	$out = @()
	foreach ($l in ($lines | Select-Object -First 5)) { $out += "  Module.bsl:${l}: $($scan.Lines[$l - 1].Trim())" }
	if ($lines.Count -gt 5) { $out += "  … и ещё $($lines.Count - 5)" }
	return ($out -join "`n")
}

# Обработчики удаляемого, которые есть процедурами в модуле, — в отчёт: мёртвый код, решает автор.
function Add-LeftHandlers([string[]]$handlers) {
	$scan = Get-ModuleScan
	if (-not $scan.Exists) { return }
	foreach ($h in $handlers) {
		if (-not $h -or $script:leftHandlers -contains $h) { continue }
		$pat = "(?im)^\s*((Асинх|Async)\s+)?(Процедура|Функция|Procedure|Function)\s+$([regex]::Escape($h))\s*\("
		if ([regex]::IsMatch($scan.Raw, $pat)) { $script:leftHandlers += $h }
	}
}

function Test-Borrowed([string]$name, [string]$kind) {
	if (-not $script:isExtension) { return $false }
	$bf = $root.SelectSingleNode("f:BaseForm", $nsMgr)
	$xp = switch ($kind) {
		'element' { ".//*[@name]" }
		'command' { "f:Commands/f:Command" }
		'attribute' { "f:Attributes/f:Attribute" }
	}
	foreach ($n in $bf.SelectNodes($xp, $nsMgr)) {
		if ($n.NamespaceURI -eq $formNs -and $n.GetAttribute("name") -eq $name) {
			if ($kind -ne 'element' -or $n.ParentNode.LocalName -eq 'ChildItems') { return $true }
		}
	}
	return $false
}

# Ближайший именованный элемент формы, которому принадлежит узел.
function Get-OwnerElement($node) {
	$cur = $node
	while ($null -ne $cur -and $cur.NodeType -eq 'Element') {
		if ($cur.NamespaceURI -eq $formNs -and $cur.HasAttribute("name") -and ($cur.ParentNode.LocalName -eq 'ChildItems' -or $script:companionTags -contains $cur.LocalName)) { return $cur }
		$cur = $cur.ParentNode
	}
	return $null
}

function Get-ElementScopes {
	$scopes = @()
	if ($null -ne $script:rootCI) { $scopes += $script:rootCI }
	$acbNode = $root.SelectSingleNode("f:AutoCommandBar", $nsMgr)
	if ($null -ne $acbNode) { $scopes += $acbNode }
	return $scopes
}

function Get-NamedInSubtree($node) {
	$names = @($node.GetAttribute("name"))
	foreach ($d in $node.SelectNodes(".//*[@name]")) {
		if ($d.NamespaceURI -eq $formNs -and ($d.ParentNode.LocalName -eq 'ChildItems' -or $script:companionTags -contains $d.LocalName)) { $names += $d.GetAttribute("name") }
	}
	return $names
}

# Общий удалитель элементов: каскад зависимых кнопок и дополнений поиска, отказ при ссылках из
# модуля и из привязанных полей, чистка условного оформления. $roots — узлы, $reasons — подпись.
function Remove-FormElements($roots, [string]$ctx, [string]$reason) {
	# Вложенные в другие удаляемые — поглощаются
	$set = New-Object System.Collections.ArrayList
	foreach ($r in $roots) {
		$inside = $false
		foreach ($o in $roots) { if (-not (Same $o $r) -and (Test-IsInside $r $o)) { $inside = $true; break } }
		if (-not $inside) { [void]$set.Add($r) }
	}
	$items = New-Object System.Collections.ArrayList   # @{ Node; Reason }
	foreach ($r in $set) { [void]$items.Add(@{ Node = $r; Reason = $reason }) }
	foreach ($r in $set) {
		foreach ($nm in (Get-NamedInSubtree $r)) {
			if (Test-Borrowed $nm 'element') { Fail "${ctx}: '$nm' — заимствованный элемент, платформа не даёт удалять его в расширении; чтобы скрыть — {""set"": ""$nm"", ""visible"": false}" }
		}
	}

	# Каскад: кнопки, дополнения поиска; отказ: прочие привязки Items.X…
	$changed = $true
	while ($changed) {
		$changed = $false
		$removedNames = @{}
		foreach ($it in $items) { foreach ($nm in (Get-NamedInSubtree $it.Node)) { $removedNames[$nm] = $nm } }
		$blockers = @()
		foreach ($s in (Get-ElementScopes)) {
			foreach ($t in $s.SelectNodes(".//*")) {
				$ln = $t.LocalName
				if (-not ($ln -eq 'CommandName' -or $ln -eq 'CommandSource' -or $ln.EndsWith('DataPath') -or ($ln -eq 'Item' -and $t.ParentNode.LocalName -eq 'AdditionSource'))) { continue }
				$txt = $t.InnerText.Trim()
				$target = $null
				if ($txt -match '^Form\.Item\.([^.]+)\.') { $target = $Matches[1] }
				elseif ($ln -eq 'CommandSource' -and $txt -match '^Item\.([^.]+)$') { $target = $Matches[1] }
				elseif ($txt -match '^Items\.([^.]+)\.') { $target = $Matches[1] }
				elseif ($ln -eq 'Item') { $target = $txt }
				if (-not $target -or -not $removedNames.ContainsKey($target)) { continue }
				$owner = Get-OwnerElement $t
				if ($null -eq $owner) { continue }
				$inRemoved = $false
				foreach ($it in $items) { if (Test-IsInside $owner $it.Node) { $inRemoved = $true; break } }
				if ($inRemoved) { continue }
				$ol = $owner.LocalName
				if ($ol -in @('Button','ButtonGroup','Popup','CommandBar','SearchStringAddition','ViewStatusAddition','SearchControlAddition')) {
					[void]$items.Add(@{ Node = $owner; Reason = "зависел от удалённого $($removedNames[$target])" })
					$changed = $true
					break
				}
				$blockers += "$($owner.GetAttribute('name')) ($ol, $ln = $txt)"
			}
			if ($changed) { break }
		}
	}
	if ($blockers.Count -gt 0) {
		Fail "${ctx}: на удаляемое ссылаются элементы, которые остаются: $(($blockers | Select-Object -Unique) -join '; ') — удали их в том же remove или перепривяжи"
	}

	# Заимствованное и ссылки из модуля — по всем удаляемым именам
	$allNames = @()
	foreach ($it in $items) { $allNames += Get-NamedInSubtree $it.Node }
	$allNames = @($allNames | Select-Object -Unique)
	foreach ($nm in $allNames) {
		if (Test-Borrowed $nm 'element') { Fail "${ctx}: '$nm' — заимствованный элемент, платформа не даёт удалять его в расширении; чтобы скрыть — {""set"": ""$nm"", ""visible"": false}" }
	}
	foreach ($nm in $allNames) {
		$refs = Find-ModuleRefs $nm 'element'
		if ($refs.Count -gt 0) { Fail "${ctx}: на элемент '$nm' ссылается модуль формы — сначала убери обращения из кода:`n$(Format-ModuleRefs $refs)" }
	}

	# Командный интерфейс формы: пункт с параметром из текущей строки удаляемого — каскадом
	$cif = $root.SelectSingleNode("f:CommandInterface", $nsMgr)
	if ($null -ne $cif) {
		$lowerNames = @{}; foreach ($nm in $allNames) { $lowerNames[$nm.ToLower()] = $true }
		foreach ($a in @($cif.SelectNodes(".//f:Item/f:Attribute", $nsMgr))) {
			if ($a.InnerText.Trim() -match '^~?Items\.([^.]+)(\.|$)' -and $lowerNames.ContainsKey($Matches[1].ToLower())) {
				$item = $a.ParentNode
				$parent = $item.ParentNode
				Remove-NodeWithWs $item
				while (-not (Same $parent $root) -and $null -eq (Get-FirstElementChild $parent)) {
					$up = $parent.ParentNode
					Remove-NodeWithWs $parent
					$parent = $up
				}
				$script:removeLog += "  - командный интерфейс: пункт с параметром $($a.InnerText.Trim())"
			}
		}
	}

	# Обработчики событий удаляемого
	$handlers = @()
	foreach ($it in $items) {
		foreach ($ev in $it.Node.SelectNodes(".//f:Event", $nsMgr)) { $handlers += $ev.InnerText.Trim() }
	}
	Add-LeftHandlers $handlers

	# Условное оформление: поле удаляемого элемента — из списка оформляемых; пустой список
	# означал бы «вся форма», поэтому такое правило уходит целиком.
	$ca = $root.SelectSingleNode("f:Attributes/f:ConditionalAppearance", $nsMgr)
	if ($null -ne $ca) {
		$lower = @{}; foreach ($nm in $allNames) { $lower[$nm.ToLower()] = $true }
		foreach ($rule in @($ca.SelectNodes("dcsset:item", $nsMgr))) {
			$sel = $rule.SelectSingleNode("dcsset:selection", $nsMgr)
			if ($null -eq $sel) { continue }
			$hit = $false
			foreach ($si in @($sel.SelectNodes("dcsset:item", $nsMgr))) {
				$f = $si.SelectSingleNode("dcsset:field", $nsMgr)
				if ($null -ne $f -and $lower.ContainsKey($f.InnerText.Trim().ToLower())) {
					$script:removeLog += "  - условное оформление: поле $($f.InnerText.Trim()) убрано из правила"
					Remove-NodeWithWs $si
					$hit = $true
				}
			}
			if ($hit -and $null -eq (Get-FirstElementChild $sel)) {
				Remove-NodeWithWs $rule
				$script:removeLog += "  - условное оформление: правило без оформляемых полей удалено"
			}
		}
		if ($null -eq (Get-FirstElementChild $ca)) { Remove-NodeWithWs $ca }
	}

	foreach ($it in $items) {
		$node = $it.Node
		$name = $node.GetAttribute("name")
		# вложенные элементы для отчёта — без служебных узлов
		$shown = @()
		foreach ($d in $node.SelectNodes(".//*[@name]")) {
			if ($d.NamespaceURI -eq $formNs -and $d.ParentNode.LocalName -eq 'ChildItems') { $shown += $d.GetAttribute("name") }
		}
		$tail = ""
		if ($shown.Count -gt 0) {
			$list = ($shown | Select-Object -First 10) -join ', '
			if ($shown.Count -gt 10) { $list += ", … и ещё $($shown.Count - 10)" }
			$tail = " (+ $list)"
		}
		$why = if ($it.Reason) { " — $($it.Reason)" } else { "" }
		$ci = $node.ParentNode
		$holder = $ci.ParentNode
		Remove-NodeWithWs $node
		Remove-IfEmptyChildItems $ci
		# Опустевшая командная панель или меню — пустым тегом, как пишет платформа
		if ($null -ne $holder -and $script:companionTags -contains $holder.LocalName -and $null -eq (Get-FirstElementChild $holder)) {
			while ($holder.HasChildNodes) { $holder.RemoveChild($holder.FirstChild) | Out-Null }
			$holder.IsEmpty = $true
		}
		$script:removeLog += "  - $name [$($node.LocalName)]$tail$why"
		$script:removedCount++
	}
}

function Invoke-Remove($op, [int]$idx) {
	$ctx = "elements[$idx] remove"
	Assert-OpKeys $op @('remove') $ctx
	$names = @(@($op.remove) | ForEach-Object { "$_" } | Where-Object { $_ })
	if ($names.Count -eq 0) { Fail "${ctx}: укажи имя элемента или список имён" }
	$nodes = @()
	$seen = @{}
	foreach ($n in $names) {
		if ($seen.ContainsKey($n)) { Fail "${ctx}: '$n' указан дважды" }
		$seen[$n] = $true
		$node = Find-FormElement $n
		if ($null -eq $node) { Fail "${ctx}: элемент '$n' не найден в форме" }
		if ($node.ParentNode.LocalName -ne 'ChildItems' -or $script:companionTags -contains $node.LocalName) {
			Fail "${ctx}: '$n' — служебный узел ($($node.LocalName)) своего элемента, удаляется только вместе с ним"
		}
		$nodes += $node
	}
	Remove-FormElements $nodes $ctx ""
}

function Remove-FormCommand($op, [int]$idx) {
	$ctx = "commands[$idx] remove"
	Assert-OpKeys $op @('remove') $ctx
	$name = "$($op.remove)"
	$sec = $root.SelectSingleNode("f:Commands", $nsMgr)
	$cmd = $null
	if ($null -ne $sec) { foreach ($c in $sec.SelectNodes("f:Command", $nsMgr)) { if ($c.GetAttribute("name") -eq $name) { $cmd = $c; break } } }
	if ($null -eq $cmd) { Fail "${ctx}: команда '$name' не найдена в форме" }
	$name = $cmd.GetAttribute("name")
	if (Test-Borrowed $name 'command') { Fail "${ctx}: '$name' — заимствованная команда, платформа не даёт удалять её в расширении" }
	$refs = Find-ModuleRefs $name 'command'
	if ($refs.Count -gt 0) { Fail "${ctx}: на команду '$name' ссылается модуль формы — сначала убери обращения из кода:`n$(Format-ModuleRefs $refs)" }

	# Кнопки команды — через общий удалитель (их имена тоже проверяются по модулю)
	$buttons = @()
	foreach ($s in (Get-ElementScopes)) {
		foreach ($cn in $s.SelectNodes(".//f:CommandName", $nsMgr)) {
			if ($cn.InnerText.Trim() -eq "Form.Command.$name") {
				$b = Get-OwnerElement $cn
				if ($null -ne $b) { $buttons += $b }
			}
		}
	}
	if ($buttons.Count -gt 0) { Remove-FormElements $buttons $ctx "кнопка удалённой команды $name" }

	# Пункты командного интерфейса формы
	$ci = $root.SelectSingleNode("f:CommandInterface", $nsMgr)
	if ($null -ne $ci) {
		foreach ($c in @($ci.SelectNodes(".//f:Item/f:Command", $nsMgr))) {
			if ($c.InnerText.Trim() -ne "Form.Command.$name") { continue }
			$item = $c.ParentNode
			$parent = $item.ParentNode
			Remove-NodeWithWs $item
			while (-not (Same $parent $root) -and $null -eq (Get-FirstElementChild $parent)) {
				$up = $parent.ParentNode
				Remove-NodeWithWs $parent
				$parent = $up
			}
			$script:removeLog += "  - командный интерфейс: пункт команды $name"
		}
	}

	Add-LeftHandlers @($cmd.SelectNodes("f:Action", $nsMgr) | ForEach-Object { $_.InnerText.Trim() })
	Remove-NodeWithWs $cmd
	if ($null -eq (Get-FirstElementChild $sec)) { Remove-NodeWithWs $sec }
	$script:removeLog += "  - команда $name"
	$script:removedCount++
}

function Remove-FormAttribute($op, [int]$idx) {
	$ctx = "attributes[$idx] remove"
	Assert-OpKeys $op @('remove') $ctx
	$name = "$($op.remove)"
	$sec = $root.SelectSingleNode("f:Attributes", $nsMgr)
	$attr = $null
	if ($null -ne $sec) { foreach ($a in $sec.SelectNodes("f:Attribute", $nsMgr)) { if ($a.GetAttribute("name") -eq $name) { $attr = $a; break } } }
	if ($null -eq $attr) { Fail "${ctx}: реквизит '$name' не найден в форме" }
	$name = $attr.GetAttribute("name")
	$main = $attr.SelectSingleNode("f:MainAttribute", $nsMgr)
	if ($null -ne $main -and $main.InnerText.Trim() -eq 'true') { Fail "${ctx}: '$name' — основной реквизит формы, он не удаляется" }
	if (Test-Borrowed $name 'attribute') { Fail "${ctx}: '$name' — заимствованный реквизит, платформа не даёт удалять его в расширении" }
	$refs = Find-ModuleRefs $name 'attribute'
	if ($refs.Count -gt 0) { Fail "${ctx}: к реквизиту '$name' обращается модуль формы — сначала убери обращения из кода:`n$(Format-ModuleRefs $refs)" }

	# Привязки в форме: пути данных элементов и поля условного оформления
	$users = @()
	$isPath = { param($t) $t -eq $name -or $t.StartsWith("$name.", [System.StringComparison]::OrdinalIgnoreCase) }
	foreach ($s in (Get-ElementScopes)) {
		foreach ($t in $s.SelectNodes(".//*")) {
			if (-not $t.LocalName.EndsWith('DataPath')) { continue }
			if (& $isPath $t.InnerText.Trim()) {
				$o = Get-OwnerElement $t
				if ($null -ne $o) { $users += "$($o.GetAttribute('name')) ($($t.LocalName))" }
			}
		}
	}
	$ca = $root.SelectSingleNode("f:Attributes/f:ConditionalAppearance", $nsMgr)
	if ($null -ne $ca) {
		foreach ($t in $ca.SelectNodes(".//dcsset:left | .//dcsset:right", $nsMgr)) {
			$xt = $t.GetAttribute("type", "http://www.w3.org/2001/XMLSchema-instance")
			if ($xt.EndsWith(':Field') -and (& $isPath $t.InnerText.Trim())) { $users += "условное оформление (отбор по $($t.InnerText.Trim()))" }
		}
	}
	$cif = $root.SelectSingleNode("f:CommandInterface", $nsMgr)
	if ($null -ne $cif) {
		foreach ($a in $cif.SelectNodes(".//f:Item/f:Attribute", $nsMgr)) {
			$at = $a.InnerText.Trim().TrimStart('~')
			if (& $isPath $at) { $users += "командный интерфейс (параметр $($a.InnerText.Trim()))" }
		}
	}
	if ($users.Count -gt 0) {
		Fail "${ctx}: к реквизиту '$name' привязаны: $(($users | Select-Object -Unique) -join '; ') — удали или перепривяжи их раньше (elements выполняются до attributes)"
	}
	Remove-NodeWithWs $attr
	if ($null -eq (Get-FirstElementChild $sec)) {
		while ($sec.HasChildNodes) { $sec.RemoveChild($sec.FirstChild) | Out-Null }
		$sec.IsEmpty = $true
	}
	$script:removeLog += "  - реквизит $name"
	$script:removedCount++
}

# === 10. Elements: добавление, перенос, изменение, удаление — по порядку ===

$script:opLog = @()
$script:addedCount = 0
$script:movedCount = 0
$script:changedCount = 0
$companionCount = 0

$elemTypeKeys = @("group","input","check","label","labelField","table","pages","page","button","picture","picField","calendar","cmdBar","popup")

if ($def.elements -and @($def.elements).Count -gt 0) {
	$ops = @($def.elements)

	# Вид каждой операции: ключ типа — добавление, move/set — над существующим элементом.
	$opKinds = @()
	for ($i = 0; $i -lt $ops.Count; $i++) {
		$op = $ops[$i]
		$kinds = @()
		foreach ($k in @('move','set','remove')) { if ($null -ne $op.PSObject.Properties[$k]) { $kinds += $k } }
		# У set ключ типа — свойство (group — ориентация); остальные ключи типа set отвергнет сам.
		if ($kinds -notcontains 'set') {
			foreach ($k in $elemTypeKeys) { if ($null -ne $op.PSObject.Properties[$k]) { $kinds += $k; break } }
		}
		if ($kinds.Count -eq 0) { Fail "elements[$i]: не понять действие — нужен тип элемента (input, group, …), move, set или remove" }
		if ($kinds.Count -gt 1) { Fail "elements[$i]: одна запись — одно действие, а здесь $($kinds -join ' и ')" }
		$opKinds += $kinds[0]
	}

	# Имена добавляемых элементов уникальны (требование 1С): внутри JSON (рекурсивно по
	# children/columns) и против уже существующих элементов формы.
	function Walk-ElemNames($el, [hashtable]$seen) {
		$tk = $null
		foreach ($k in $elemTypeKeys) { if ($el.$k -ne $null) { $tk = $k; break } }
		if ($tk) { Assert-EditUnique -name (Get-ElementName -el $el -typeKey $tk) -seen $seen -ctx 'element name' }
		if ($el.children) { foreach ($c in $el.children) { Walk-ElemNames $c $seen } }
		if ($el.columns)  { foreach ($c in $el.columns)  { Walk-ElemNames $c $seen } }
	}
	$dslElemNames = @{}
	for ($i = 0; $i -lt $ops.Count; $i++) {
		if ($opKinds[$i] -in @('move','set','remove')) { continue }
		Walk-ElemNames $ops[$i] $dslElemNames
	}

	$startElemId = $script:nextElemId
	for ($i = 0; $i -lt $ops.Count; $i++) {
		switch ($opKinds[$i]) {
			'move' { Invoke-Move $ops[$i] $i }
			'set'  { Invoke-Set $ops[$i] $i }
			'remove' { Invoke-Remove $ops[$i] $i }
			default { Invoke-Add $ops[$i] $opKinds[$i] $i }
		}
	}
	$companionCount = ($script:nextElemId - $startElemId) - $script:addedCount
}

# === 11. Add attributes ===

$addedAttrs = @()

# Удаления (запись с ключом remove) — по порядку, до добавлений
$attrAdds = @()
if ($def.attributes) {
	$attrOps = @($def.attributes)
	for ($i = 0; $i -lt $attrOps.Count; $i++) {
		if ($null -ne $attrOps[$i].PSObject.Properties['remove']) {
			Assert-OpKeys $attrOps[$i] @('remove') "attributes[$i] remove"
			foreach ($rn in @(@($attrOps[$i].remove) | ForEach-Object { "$_" })) { Remove-FormAttribute ([pscustomobject]@{ remove = $rn }) $i }
		} else { $attrAdds += $attrOps[$i] }
	}
}

if ($attrAdds.Count -gt 0) {
	$attrsSection = $root.SelectSingleNode("f:Attributes", $nsMgr)
	if (-not $attrsSection) {
		# Create Attributes section — insert after ChildItems or after Events
		$attrsSection = $xmlDoc.CreateElement("Attributes", $formNs)
		# Find insertion point: after ChildItems or after the last pre-Attributes element
		$insertAfter = $rootCI
		if (-not $insertAfter) {
			$insertAfter = $root.SelectSingleNode("f:Events", $nsMgr)
		}
		if (-not $insertAfter) {
			$insertAfter = $root.SelectSingleNode("f:AutoCommandBar", $nsMgr)
		}
		if ($insertAfter) {
			$refNode = $insertAfter.NextSibling
			$ws = $xmlDoc.CreateWhitespace("`r`n`t")
			$root.InsertBefore($ws, $refNode) | Out-Null
			$root.InsertBefore($attrsSection, $refNode) | Out-Null
		} else {
			$root.AppendChild($xmlDoc.CreateWhitespace("`r`n`t")) | Out-Null
			$root.AppendChild($attrsSection) | Out-Null
		}
	}

	# Detect indent for attribute children
	$attrChildIndent = Get-ChildIndent $attrsSection
	if (-not $attrChildIndent -or $attrChildIndent -eq "") { $attrChildIndent = "`t`t" }

	# Уникальность имён реквизитов: внутри JSON-определения (+ колонки в пределах реквизита) и
	# против уже существующих реквизитов формы.
	$dslAttrNames = @{}
	foreach ($attr in $attrAdds) {
		Assert-EditUnique -name "$($attr.name)" -seen $dslAttrNames -ctx 'attribute name'
		if ($attr.columns) {
			$dslColNames = @{}
			foreach ($col in $attr.columns) { Assert-EditUnique -name "$($col.name)" -seen $dslColNames -ctx "column name of '$($attr.name)'" }
		}
		$existingAttr = $attrsSection.SelectSingleNode("f:Attribute[@name='$($attr.name)']", $nsMgr)
		if ($existingAttr) {
			Write-Host "[ERROR] Attribute '$($attr.name)' already exists in form — attribute names must be unique"
			exit 1
		}
	}

	# Generate attribute fragments
	$script:xml = New-Object System.Text.StringBuilder 2048
	X "<_F $allNsDecl>"
	foreach ($attr in $attrAdds) {
		$attrId = New-AttrId
		$attrName = "$($attr.name)"
		X "$attrChildIndent<Attribute name=`"$attrName`" id=`"$attrId`">"
		$inner = "$attrChildIndent`t"

		if ($attr.title) { Emit-MLText -tag "Title" -text "$($attr.title)" -indent $inner }
		if ($attr.type) { Emit-Type -typeStr "$($attr.type)" -indent $inner } else { X "$inner<Type/>" }
		if ($attr.main -eq $true) { X "$inner<MainAttribute>true</MainAttribute>" }
		if ($attr.savedData -eq $true) { X "$inner<SavedData>true</SavedData>" }
		if ($attr.fillChecking) { X "$inner<FillChecking>$($attr.fillChecking)</FillChecking>" }

		if ($attr.columns -and $attr.columns.Count -gt 0) {
			X "$inner<Columns>"
			$colId = 1
			foreach ($col in $attr.columns) {
				X "$inner`t<Column name=`"$($col.name)`" id=`"$colId`">"
				if ($col.title) { Emit-MLText -tag "Title" -text "$($col.title)" -indent "$inner`t`t" }
				Emit-Type -typeStr "$($col.type)" -indent "$inner`t`t"
				X "$inner`t</Column>"
				$colId++
			}
			X "$inner</Columns>"
		}

		X "$attrChildIndent</Attribute>"
		$typeStr = if ($attr.type) { "$($attr.type)" } else { "(no type)" }
		$addedAttrs += "  + ${attrName}: $typeStr (id=$attrId)"
	}
	X "</_F>"

	$fragDoc = Parse-Fragment $script:xml.ToString()
	$importedAttrs = Import-ElementNodes $fragDoc

	foreach ($node in $importedAttrs) {
		Insert-IntoContainer -container $attrsSection -newNode $node -afterName $null -childIndent $attrChildIndent
	}
}

# === 12. Add commands ===

$addedCmds = @()

# Удаления (запись с ключом remove) — по порядку, до добавлений
$cmdAdds = @()
if ($def.commands) {
	$cmdOps = @($def.commands)
	for ($i = 0; $i -lt $cmdOps.Count; $i++) {
		if ($null -ne $cmdOps[$i].PSObject.Properties['remove']) {
			Assert-OpKeys $cmdOps[$i] @('remove') "commands[$i] remove"
			foreach ($rn in @(@($cmdOps[$i].remove) | ForEach-Object { "$_" })) { Remove-FormCommand ([pscustomobject]@{ remove = $rn }) $i }
		} else { $cmdAdds += $cmdOps[$i] }
	}
}

if ($cmdAdds.Count -gt 0) {
	$cmdsSection = $root.SelectSingleNode("f:Commands", $nsMgr)
	if (-not $cmdsSection) {
		# Секция команд — после Attributes (порядок платформы: Attributes, Commands, Parameters)
		$cmdsSection = $xmlDoc.CreateElement("Commands", $formNs)
		$insertAfter = $root.SelectSingleNode("f:Attributes", $nsMgr)
		if (-not $insertAfter) { $insertAfter = $rootCI }
		if (-not $insertAfter) { $insertAfter = $root.SelectSingleNode("f:Events", $nsMgr) }
		if (-not $insertAfter) { $insertAfter = $root.SelectSingleNode("f:AutoCommandBar", $nsMgr) }
		if ($insertAfter) {
			$refNode = $insertAfter.NextSibling
			$ws = $xmlDoc.CreateWhitespace("`r`n`t")
			$root.InsertBefore($ws, $refNode) | Out-Null
			$root.InsertBefore($cmdsSection, $refNode) | Out-Null
		} else {
			$root.AppendChild($xmlDoc.CreateWhitespace("`r`n`t")) | Out-Null
			$root.AppendChild($cmdsSection) | Out-Null
		}
	}

	$cmdChildIndent = Get-ChildIndent $cmdsSection
	if (-not $cmdChildIndent -or $cmdChildIndent -eq "") { $cmdChildIndent = "`t`t" }

	# Уникальность имён команд: внутри JSON-определения и против существующих команд формы.
	$dslCmdNames = @{}
	foreach ($cmd in $cmdAdds) {
		Assert-EditUnique -name "$($cmd.name)" -seen $dslCmdNames -ctx 'command name'
		$existingCmd = $cmdsSection.SelectSingleNode("f:Command[@name='$($cmd.name)']", $nsMgr)
		if ($existingCmd) {
			Write-Host "[ERROR] Command '$($cmd.name)' already exists in form — command names must be unique"
			exit 1
		}
	}

	# Generate command fragments
	$script:xml = New-Object System.Text.StringBuilder 1024
	X "<_F $allNsDecl>"
	foreach ($cmd in $cmdAdds) {
		$cmdId = New-CmdId
		$cmdName = "$($cmd.name)"
		X "$cmdChildIndent<Command name=`"$cmdName`" id=`"$cmdId`">"
		$inner = "$cmdChildIndent`t"

		if ($cmd.title) { Emit-MLText -tag "Title" -text "$($cmd.title)" -indent $inner }

		# Support single action with optional callType, or multiple actions
		if ($cmd.actions) {
			# Multiple actions: [{ "callType": "Before", "handler": "..." }, ...]
			foreach ($act in $cmd.actions) {
				$actHandler = "$($act.handler)"
				$callTypeAttr = if ($act.callType) { " callType=`"$($act.callType)`"" } else { "" }
				X "$inner<Action$callTypeAttr>$actHandler</Action>"
			}
		} elseif ($cmd.action) {
			$callTypeAttr = if ($cmd.callType) { " callType=`"$($cmd.callType)`"" } else { "" }
			X "$inner<Action$callTypeAttr>$($cmd.action)</Action>"
		}

		if ($cmd.shortcut) { X "$inner<Shortcut>$($cmd.shortcut)</Shortcut>" }
		if ($cmd.picture) {
			X "$inner<Picture>"
			X "$inner`t<xr:Ref>$($cmd.picture)</xr:Ref>"
			X "$inner`t<xr:LoadTransparent>true</xr:LoadTransparent>"
			X "$inner</Picture>"
		}
		if ($cmd.representation) { X "$inner<Representation>$($cmd.representation)</Representation>" }

		X "$cmdChildIndent</Command>"
		$actionStr = if ($cmd.action) { " -> $($cmd.action)" } elseif ($cmd.actions) { " -> $($cmd.actions.Count) action(s)" } else { "" }
		$addedCmds += "  + ${cmdName}${actionStr} (id=$cmdId)"
	}
	X "</_F>"

	$fragDoc = Parse-Fragment $script:xml.ToString()
	$importedCmds = Import-ElementNodes $fragDoc

	foreach ($node in $importedCmds) {
		Insert-IntoContainer -container $cmdsSection -newNode $node -afterName $null -childIndent $cmdChildIndent
	}
}

# === 12b. Add form-level events ===

$addedFormEvents = @()

if ($def.formEvents -and $def.formEvents.Count -gt 0) {
	$eventsSection = $root.SelectSingleNode("f:Events", $nsMgr)
	if (-not $eventsSection) {
		# Create Events section — insert after AutoCommandBar or at the beginning
		$eventsSection = $xmlDoc.CreateElement("Events", $formNs)
		$insertAfter = $root.SelectSingleNode("f:AutoCommandBar", $nsMgr)
		if ($insertAfter) {
			# Insert after AutoCommandBar (Events come after AutoCommandBar in 1C)
			$ws1 = $xmlDoc.CreateWhitespace("`r`n`t")
			$ws2 = $xmlDoc.CreateWhitespace("`r`n`t")
			if ($insertAfter.NextSibling) {
				$root.InsertBefore($ws1, $insertAfter.NextSibling) | Out-Null
				$root.InsertBefore($eventsSection, $ws1) | Out-Null
				$root.InsertBefore($ws2, $eventsSection) | Out-Null
			} else {
				$root.AppendChild($xmlDoc.CreateWhitespace("`r`n`t")) | Out-Null
				$root.AppendChild($eventsSection) | Out-Null
				$root.AppendChild($xmlDoc.CreateWhitespace("`r`n")) | Out-Null
			}
		} else {
			$firstChild = $root.FirstChild
			if ($firstChild) {
				$ws = $xmlDoc.CreateWhitespace("`r`n`t")
				$root.InsertBefore($eventsSection, $firstChild) | Out-Null
				$root.InsertBefore($ws, $eventsSection) | Out-Null
			} else {
				$root.AppendChild($xmlDoc.CreateWhitespace("`r`n`t")) | Out-Null
				$root.AppendChild($eventsSection) | Out-Null
			}
		}
	}

	$evtChildIndent = Get-ChildIndent $eventsSection
	if (-not $evtChildIndent -or $evtChildIndent -eq "") { $evtChildIndent = "`t`t" }

	# Generate event fragments
	$script:xml = New-Object System.Text.StringBuilder 512
	X "<_F $allNsDecl>"
	foreach ($fe in $def.formEvents) {
		$feName = "$($fe.name)"
		$feHandler = "$($fe.handler)"
		$callTypeAttr = if ($fe.callType) { " callType=`"$($fe.callType)`"" } else { "" }
		X "$evtChildIndent<Event name=`"$feName`"$callTypeAttr>$feHandler</Event>"
		$ctStr = if ($fe.callType) { "[$($fe.callType)]" } else { "" }
		$addedFormEvents += "  + $feName${ctStr} -> $feHandler"
	}
	X "</_F>"

	$fragDoc = Parse-Fragment $script:xml.ToString()
	$importedEvents = Import-ElementNodes $fragDoc

	foreach ($node in $importedEvents) {
		Insert-IntoContainer -container $eventsSection -newNode $node -afterName $null -childIndent $evtChildIndent
	}
}

# === 12c. Add element-level events ===

$addedElemEvents = @()

if ($def.elementEvents -and $def.elementEvents.Count -gt 0) {
	if (-not $rootCI) {
		$rootCI = $root.SelectSingleNode("f:ChildItems", $nsMgr)
	}

	foreach ($ee in $def.elementEvents) {
		$targetName = "$($ee.element)"
		$targetEl = Find-Element $rootCI $targetName
		if (-not $targetEl) {
			Write-Host "[WARN] Element '$targetName' not found — skipping elementEvent"
			continue
		}

		# Find or create Events element within the target
		$targetEvents = $targetEl.SelectSingleNode("f:Events", $nsMgr)
		if (-not $targetEvents) {
			$targetEvents = $xmlDoc.CreateElement("Events", $formNs)
			# Insert Events before closing tag (after last property, before ChildItems if any)
			$ciNode = $targetEl.SelectSingleNode("f:ChildItems", $nsMgr)
			if ($ciNode) {
				$ws = $xmlDoc.CreateWhitespace("`r`n" + (Get-ChildIndent $targetEl))
				$targetEl.InsertBefore($ws, $ciNode) | Out-Null
				$targetEl.InsertBefore($targetEvents, $ciNode) | Out-Null
			} else {
				$trailing = $targetEl.LastChild
				if ($trailing -and ($trailing.NodeType -eq 'Whitespace' -or $trailing.NodeType -eq 'SignificantWhitespace')) {
					$ws = $xmlDoc.CreateWhitespace("`r`n" + (Get-ChildIndent $targetEl))
					$targetEl.InsertBefore($ws, $trailing) | Out-Null
					$targetEl.InsertBefore($targetEvents, $trailing) | Out-Null
				} else {
					$targetEl.AppendChild($xmlDoc.CreateWhitespace("`r`n" + (Get-ChildIndent $targetEl))) | Out-Null
					$targetEl.AppendChild($targetEvents) | Out-Null
				}
			}
		}

		$eeChildIndent = Get-ChildIndent $targetEvents
		if (-not $eeChildIndent -or $eeChildIndent -eq "") {
			$parentIndent = Get-ChildIndent $targetEl
			$eeChildIndent = "$parentIndent`t"
		}

		# Create Event element
		$eeName = "$($ee.name)"
		$eeHandler = "$($ee.handler)"
		$callTypeAttr = if ($ee.callType) { " callType=`"$($ee.callType)`"" } else { "" }

		$script:xml = New-Object System.Text.StringBuilder 256
		X "<_F $allNsDecl>"
		X "$eeChildIndent<Event name=`"$eeName`"$callTypeAttr>$eeHandler</Event>"
		X "</_F>"

		$fragDoc = Parse-Fragment $script:xml.ToString()
		$importedEE = Import-ElementNodes $fragDoc

		foreach ($node in $importedEE) {
			Insert-IntoContainer -container $targetEvents -newNode $node -afterName $null -childIndent $eeChildIndent
		}

		$ctStr = if ($ee.callType) { "[$($ee.callType)]" } else { "" }
		$addedElemEvents += "  + $targetName.$eeName${ctStr} -> $eeHandler"
	}
}

# === 13. Save ===

$content = $xmlDoc.OuterXml
# Ensure encoding declaration is uppercase UTF-8
$content = $content -replace '^<\?xml version="1.0" encoding="utf-8"\?>', '<?xml version="1.0" encoding="UTF-8"?>'
# Пустой элемент: XmlWriter отдаёт `<a />`, Конфигуратор пишет `<a/>`. Внутри
# CDATA/комментария ` />` может быть содержимым (там `>` не экранируется),
# поэтому они идут первыми ветками альтернации и возвращаются как есть.
$content = [regex]::Replace($content, '(?s)<!\[CDATA\[.*?\]\]>|<!--.*?-->|(?<=\S) />', { param($m) if ($m.Value -eq ' />') { '/>' } else { $m.Value } })

# BOM — как у файла-назначения: правка не меняет того, о чём не просили (#44/#46/#47).
# Выгрузка платформы всегда с BOM; без BOM — только файл, созданный не платформой.
$targetBom = $true
if (Test-Path -LiteralPath $resolvedFormPath) {
	$head = [System.IO.File]::ReadAllBytes($resolvedFormPath)
	$targetBom = ($head.Length -ge 3 -and $head[0] -eq 0xEF -and $head[1] -eq 0xBB -and $head[2] -eq 0xBF)
}
$enc = New-Object System.Text.UTF8Encoding($targetBom)
# Целевой перевод строки: стиль файла-назначения — правка наследует его (#44/#46/#47),
# новый файл получает канон выгрузки CRLF. Зеркало _detect_xml_style в py-порту.
$targetEol = if ((Test-Path -LiteralPath $resolvedFormPath) -and ([System.IO.File]::ReadAllText($resolvedFormPath) -notmatch "`r`n")) { "`n" } else { "`r`n" }
$content = ($content -replace "`r`n", "`n") -replace "`n", $targetEol
[System.IO.File]::WriteAllText($resolvedFormPath, $content, $enc)

# === 14. Summary ===

if ($script:isExtension) {
	Write-Host "[EXTENSION] BaseForm detected — IDs start at 1000000+"
	Write-Host ""
}

if ($addedFormEvents.Count -gt 0) {
	Write-Host "Added form events:"
	foreach ($line in $addedFormEvents) { Write-Host $line }
	Write-Host ""
}

if ($addedElemEvents.Count -gt 0) {
	Write-Host "Added element events:"
	foreach ($line in $addedElemEvents) { Write-Host $line }
	Write-Host ""
}

if ($script:opLog.Count -gt 0) {
	Write-Host "Elements:"
	foreach ($line in $script:opLog) { Write-Host $line }
	Write-Host ""
}

if ($script:removeLog.Count -gt 0) {
	Write-Host "Removed:"
	foreach ($line in $script:removeLog) { Write-Host $line }
	Write-Host ""
}

if ($script:leftHandlers.Count -gt 0) {
	Write-Host "Handlers left in module (delete if unused):"
	foreach ($h in $script:leftHandlers) { Write-Host "  $h" }
	Write-Host ""
}

if ($addedAttrs.Count -gt 0) {
	Write-Host "Added attributes:"
	foreach ($line in $addedAttrs) { Write-Host $line }
	Write-Host ""
}

if ($addedCmds.Count -gt 0) {
	Write-Host "Added commands:"
	foreach ($line in $addedCmds) { Write-Host $line }
	Write-Host ""
}

Write-Host "---"
$totalParts = @()
if ($addedFormEvents.Count -gt 0) { $totalParts += "$($addedFormEvents.Count) form event(s)" }
if ($addedElemEvents.Count -gt 0) { $totalParts += "$($addedElemEvents.Count) element event(s)" }
if ($script:addedCount -gt 0) {
	$compStr = if ($companionCount -gt 0) { " (+$companionCount companions)" } else { "" }
	$totalParts += "$($script:addedCount) element(s)$compStr"
}
if ($script:movedCount -gt 0) { $totalParts += "$($script:movedCount) moved" }
if ($script:changedCount -gt 0) { $totalParts += "$($script:changedCount) property change(s)" }
if ($script:removedCount -gt 0) { $totalParts += "$($script:removedCount) removed" }
if ($addedAttrs.Count -gt 0) { $totalParts += "$($addedAttrs.Count) attribute(s)" }
if ($addedCmds.Count -gt 0) { $totalParts += "$($addedCmds.Count) command(s)" }
Write-Host "Total: $($totalParts -join ', ')"
Write-Host "Run /form-validate to verify."
