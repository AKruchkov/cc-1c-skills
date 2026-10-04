# form-edit v1.23 — Edit 1C managed form elements
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


# --- Event handler name generator ---


# --- Element helpers ---


# Уникальность имён внутри JSON-определения (1С: своя коллекция — свой неймспейс).
function Assert-EditUnique {
	param([string]$name, [hashtable]$seen, [string]$ctx)
	if ($seen.ContainsKey($name)) {
		Write-Host "[ERROR] Duplicate $ctx '$name' in JSON definition — names must be unique in 1C form"
		exit 1
	}
	$seen[$name] = $true
}


# --- Element emitters ---


# --- Element dispatcher ---


# === 5b. Эмиттер элементов — общий с form-compile (эталон там; копии держит check-inline-drift) ===

$script:fmtMarkupRe = '</>|<\s*(?:link|b|i|u|s|color|colorStyle|bgColor|bgColorStyle|font|fontSize|fontStyle|img)(?:\s|>)'

$script:knownInvalidTypes = @{
	"FormDataStructure"     = "Runtime type. Use object type without cfg: prefix (e.g. CatalogObject.Контрагенты, DocumentObject.Приход)"
	"FormDataCollection"    = "Runtime type. Use ValueTable"
	"FormDataTree"          = "Runtime type. Use ValueTree"
	"FormDataTreeItem"      = "Runtime type, not valid in XML"
	"FormDataCollectionItem"= "Runtime type, not valid in XML"
	"FormGroup"             = "UI element type, not a data type"
	"FormField"             = "UI element type, not a data type"
	"FormButton"            = "UI element type, not a data type"
	"FormDecoration"        = "UI element type, not a data type"
	"FormTable"             = "UI element type, not a data type"
}

$script:typeSynonyms = $script:formTypeSynonyms

$script:eventSuffixMap = @{
	"OnChange"             = "ПриИзменении"
	"StartChoice"          = "НачалоВыбора"
	"ChoiceProcessing"     = "ОбработкаВыбора"
	"AutoComplete"         = "АвтоПодбор"
	"Clearing"             = "Очистка"
	"Opening"              = "Открытие"
	"Click"                = "Нажатие"
	"OnActivateRow"        = "ПриАктивизацииСтроки"
	"BeforeAddRow"         = "ПередНачаломДобавления"
	"BeforeDeleteRow"      = "ПередУдалением"
	"BeforeRowChange"      = "ПередНачаломИзменения"
	"OnStartEdit"          = "ПриНачалеРедактирования"
	"OnEditEnd"            = "ПриОкончанииРедактирования"
	"Selection"            = "ВыборСтроки"
	"OnCurrentPageChange"  = "ПриСменеСтраницы"
	"TextEditEnd"          = "ОкончаниеВводаТекста"
	"URLProcessing"        = "ОбработкаНавигационнойСсылки"
	"DragStart"            = "НачалоПеретаскивания"
	"Drag"                 = "Перетаскивание"
	"DragCheck"            = "ПроверкаПеретаскивания"
	"Drop"                 = "Помещение"
	"AfterDeleteRow"       = "ПослеУдаления"
}

$script:knownEvents = @{
	"input"     = @("OnChange","StartChoice","ChoiceProcessing","AutoComplete","TextEditEnd","Clearing","Creating","EditTextChange")
	"check"     = @("OnChange")
	"radio"     = @("OnChange")
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

$script:companionStructKeys = @(
	'width','autoMaxWidth','maxWidth','height','autoMaxHeight','maxHeight','verticalAlign','titleHeight',
	'horizontalStretch','verticalStretch','horizontalAlign','groupHorizontalAlign','groupVerticalAlign',
	'visible','hidden','enabled','disabled','hyperlink','events','tooltip',
	'textColor','backColor','borderColor','font','border','цветтекста','цветфона','цветрамки','шрифт','рамка'
)

$script:additionTypeMap = [ordered]@{
	'searchString'  = @{ Tag = 'SearchStringAddition';  Type = 'SearchStringRepresentation'; Suffix = 'СтрокаПоиска' }
	'viewStatus'    = @{ Tag = 'ViewStatusAddition';    Type = 'ViewStatusRepresentation';   Suffix = 'СостояниеПросмотра' }
	'searchControl' = @{ Tag = 'SearchControlAddition'; Type = 'SearchControl';               Suffix = 'УправлениеПоиском' }
}

$script:additionKeySynonyms = @{
	'searchString'  = @('SearchStringAddition','SearchStringRepresentation','строкаПоиска','отображениеСтрокиПоиска')
	'viewStatus'    = @('ViewStatusAddition','ViewStatusRepresentation','состояниеПросмотра')
	'searchControl' = @('SearchControlAddition','SearchControl','управлениеПоиском')
}

$script:elementTypeStrOnlyKeys = @('commandBar','autoCommandBar','КоманднаяПанель')

$script:elementTypeSynonyms = @{
	"commandBar"        = "cmdBar"
	"autoCommandBar"    = "autoCmdBar"
	"КоманднаяПанель"   = "cmdBar"
	"InputField"        = "input"
	"ПолеВвода"         = "input"
	"CheckBoxField"     = "check"
	"ПолеФлажка"        = "check"
	"RadioButtonField"  = "radio"
	"ПолеПереключателя" = "radio"
	"radioButton"       = "radio"
	"PictureField"      = "picField"
	"ПолеКартинки"      = "picField"
	"LabelField"        = "labelField"
	"ПолеНадписи"       = "labelField"
	"CalendarField"     = "calendar"
	"ПолеКалендаря"     = "calendar"
	"LabelDecoration"   = "label"
	"Надпись"           = "label"
	"PictureDecoration" = "picture"
	"Картинка"          = "picture"
	"UsualGroup"        = "group"
	"Группа"            = "group"
	"ОбычнаяГруппа"     = "group"
	"ColumnGroup"       = "columnGroup"
	"ГруппаКолонок"     = "columnGroup"
	"Pages"             = "pages"
	"ГруппаСтраниц"     = "pages"
	"Page"              = "page"
	"Страница"          = "page"
	"Table"             = "table"
	"Таблица"           = "table"
	"Button"            = "button"
	"Кнопка"            = "button"
	"Popup"             = "popup"
	"ВсплывающееМеню"   = "popup"
	# Дополнения командной панели таблицы (тип-как-ключ) — forgiving: XML-тег/Type/рус.имя → канон
	"SearchStringAddition"       = "searchString"
	"SearchStringRepresentation" = "searchString"
	"строкаПоиска"               = "searchString"
	"отображениеСтрокиПоиска"    = "searchString"
	"Отображение строки поиска"  = "searchString"
	"ViewStatusAddition"         = "viewStatus"
	"ViewStatusRepresentation"   = "viewStatus"
	"состояниеПросмотра"         = "viewStatus"
	"Состояние просмотра"        = "viewStatus"
	"SearchControlAddition"      = "searchControl"
	"SearchControl"              = "searchControl"
	"управлениеПоиском"          = "searchControl"
	"Управление поиском"         = "searchControl"
	# Спец-поля (документ/датчик) — XML-имя/рус. → канон
	"SpreadSheetDocumentField"   = "spreadsheet"
	"ПолеТабличногоДокумента"    = "spreadsheet"
	"HTMLDocumentField"          = "html"
	"ПолеHTMLДокумента"          = "html"
	"TextDocumentField"          = "textDoc"
	"ПолеТекстовогоДокумента"    = "textDoc"
	"FormattedDocumentField"     = "formattedDoc"
	"ПолеФорматированногоДокумента" = "formattedDoc"
	"ProgressBarField"           = "progressBar"
	"ПолеИндикатора"             = "progressBar"
	"TrackBarField"              = "trackBar"
	"ПолеПолосыРегулирования"    = "trackBar"
	"ChartField"                 = "chart"
	"ПолеДиаграммы"              = "chart"
	"GanttChartField"            = "ganttChart"
	"ПолеДиаграммыГанта"         = "ganttChart"
	"GraphicalSchemaField"       = "graphicalSchema"
	"ПолеГрафическойСхемы"       = "graphicalSchema"
	"PlannerField"               = "planner"
	"ПолеПланировщика"           = "planner"
	"PeriodField"                = "periodField"
	"ПолеПериода"                = "periodField"
	"DendrogramField"            = "dendrogram"
	"ПолеДендрограммы"           = "dendrogram"
}

$script:appearanceSpec = @{
	titleTextColor  = @{ tag='TitleTextColor';  kind='color' }
	titleBackColor  = @{ tag='TitleBackColor';  kind='color' }
	titleFont       = @{ tag='TitleFont';       kind='font'  }
	footerTextColor = @{ tag='FooterTextColor'; kind='color' }
	footerBackColor = @{ tag='FooterBackColor'; kind='color' }
	footerFont      = @{ tag='FooterFont';      kind='font'  }
	textColor       = @{ tag='TextColor';       kind='color' }
	backColor       = @{ tag='BackColor';       kind='color' }
	borderColor     = @{ tag='BorderColor';     kind='color' }
	border          = @{ tag='Border';          kind='border'}
	font            = @{ tag='Font';            kind='font'  }
}

$script:appearanceSynonyms = @{
	'цветтекста'='textColor'; 'цветфона'='backColor'; 'цветрамки'='borderColor'
	'цветтекстазаголовка'='titleTextColor'; 'цветфоназаголовка'='titleBackColor'; 'шрифтзаголовка'='titleFont'
	'цветтекстаподвала'='footerTextColor'; 'цветфонаподвала'='footerBackColor'; 'шрифтподвала'='footerFont'
	'шрифт'='font'; 'рамка'='border'
}

$script:propSynonyms = @{
	'пометка'='checked'
	'кнопкавыбора'='choiceButton'; 'кнопкаочистки'='clearButton'; 'кнопкарегулирования'='spinButton'
	'кнопкавыпадающегосписка'='dropListButton'; 'кнопкасписковоговыбора'='choiceListButton'
	'кнопкаоткрытия'='openButton'; 'кнопкапоумолчанию'='defaultButton'
	'быстрыйвыбор'='quickChoice'; 'формавыбора'='choiceForm'; 'историявыборапривводе'='choiceHistoryOnInput'
	'выборгруппиэлементов'='choiceFoldersAndItems'; 'фиксациявтаблице'='fixingInTable'
	'путькданнымподвала'='footerDataPath'; 'автоотметканезаполненного'='markIncomplete'
	'многострочныйрежим'='multiLine'; 'режимпароля'='passwordMode'; 'переноспословам'='wrap'
	'расположениезаголовка'='titleLocation'; 'пропускатьпривводе'='skipOnInput'
	'заголовок'='title'; 'ширина'='width'; 'высота'='height'; 'подсказкаввода'='inputHint'
}

$script:appOrderField      = @('titleTextColor','titleBackColor','titleFont','footerTextColor','footerBackColor','footerFont','textColor','backColor','borderColor','border','font')

$script:appOrderDecoration = @('textColor','font','backColor','borderColor','border')

$script:appOrderButton     = @('textColor','backColor','borderColor','font')

$script:genericScalars = @(
	@{ Tag='VerticalAlign';       Key='verticalAlign';       Kind='value' }
	@{ Tag='ThroughAlign';        Key='throughAlign';        Kind='value' }
	@{ Tag='EnableContentChange'; Key='enableContentChange'; Kind='bool'  }
	@{ Tag='PictureSize';         Key='pictureSize';         Kind='value' }
	@{ Tag='TitleHeight';         Key='titleHeight';         Kind='value' }
	@{ Tag='ChildItemsWidth';     Key='childItemsWidth';     Kind='value' }
	@{ Tag='ShowLeftMargin';      Key='showLeftMargin';      Kind='bool'  }
	@{ Tag='CellHyperlink';       Key='cellHyperlink';       Kind='bool'  }
	@{ Tag='ViewMode';            Key='viewMode';            Kind='value' }
	@{ Tag='VerticalScrollBar';   Key='verticalScrollBar';   Kind='value' }
	@{ Tag='RowInputMode';        Key='rowInputMode';        Kind='value' }
	@{ Tag='Mask';                Key='mask';                Kind='value' }
	@{ Tag='CreateButton';        Key='createButton';        Kind='bool'  }
	@{ Tag='FixingInTable';       Key='fixingInTable';       Kind='value' }
	@{ Tag='VerticalSpacing';     Key='verticalSpacing';     Kind='value' }
	# Спец-поля (документ/датчик) — типоспец. enum/bool скаляры pass-through
	@{ Tag='HorizontalScrollBar'; Key='horizontalScrollBar'; Kind='value' }
	@{ Tag='ViewScalingMode';     Key='viewScalingMode';     Kind='value' }
	@{ Tag='Output';              Key='output';              Kind='value' }
	@{ Tag='SelectionShowMode';   Key='selectionShowMode';   Kind='value' }
	@{ Tag='PointerType';         Key='pointerType';         Kind='value' }
	@{ Tag='DrawingSelectionShowMode'; Key='drawingSelectionShowMode'; Kind='value' }
	@{ Tag='WarningOnEditRepresentation'; Key='warningOnEditRepresentation'; Kind='value' }
	@{ Tag='MarkingAppearance';   Key='markingAppearance';   Kind='value' }
	@{ Tag='Protection';          Key='protection';          Kind='bool'  }
	@{ Tag='Edit';                Key='edit';                Kind='bool'  }
	@{ Tag='ShowGrid';            Key='showGrid';            Kind='bool'  }
	@{ Tag='ShowGroups';          Key='showGroups';          Kind='bool'  }
	@{ Tag='ShowHeaders';         Key='showHeaders';         Kind='bool'  }
	@{ Tag='ShowRowAndColumnNames'; Key='showRowAndColumnNames'; Kind='bool' }
	@{ Tag='ShowCellNames';       Key='showCellNames';       Kind='bool'  }
	@{ Tag='ShowPercent';         Key='showPercent';         Kind='bool'  }
	# Report-form контекст: интервал группы / представление кнопки в контекстном меню / детальное представление настройки таблицы
	@{ Tag='HorizontalSpacing';   Key='horizontalSpacing';   Kind='value' }
	@{ Tag='RepresentationInContextMenu'; Key='representationInContextMenu'; Kind='value' }
	@{ Tag='SettingsNamedItemDetailedRepresentation'; Key='settingsNamedItemDetailedRepresentation'; Kind='bool' }
	# Хвост: высота элемента списка (radio) / ширина выпадающего списка (input)
	@{ Tag='ItemHeight';          Key='itemHeight';          Kind='value' }
	@{ Tag='DropListWidth';       Key='dropListWidth';       Kind='value' }
	# Хвост CI-форм: динамический заголовок (Page/Group) / расширенное ред. (input) / высота таблицы по строкам
	@{ Tag='TitleDataPath';       Key='titleDataPath';       Kind='value' }
	@{ Tag='ExtendedEdit';        Key='extendedEdit';        Kind='bool'  }
	@{ Tag='MaxRowsCount';        Key='maxRowsCount';        Kind='value' }
	@{ Tag='AutoMaxRowsCount';    Key='autoMaxRowsCount';    Kind='bool'  }
	@{ Tag='HeightControlVariant'; Key='heightControlVariant'; Kind='value' }
	@{ Tag='EditTextUpdate';      Key='editTextUpdate';      Kind='value' }
	# Корпусный хвост: представление управления свёрткой группы / форма кнопки-попапа /
	# авто-добавление незаполненной строки / выделение отрицательных / нач. позиция списка /
	# высота списка выбора / три состояния флажка / прокрутка страницы при сжатии
	@{ Tag='ControlRepresentation'; Key='controlRepresentation'; Kind='value' }
	@{ Tag='ShapeRepresentation';   Key='shapeRepresentation';   Kind='value' }
	@{ Tag='AutoAddIncomplete';     Key='autoAddIncomplete';     Kind='bool'  }
	@{ Tag='MarkNegatives';         Key='markNegatives';         Kind='bool'  }
	@{ Tag='InitialListView';       Key='initialListView';       Kind='value' }
	@{ Tag='ChoiceListHeight';      Key='choiceListHeight';      Kind='value' }
	@{ Tag='ThreeState';            Key='threeState';            Kind='bool'  }
	@{ Tag='ScrollOnCompress';      Key='scrollOnCompress';      Kind='bool'  }
	# Сочетание клавиш — общее свойство (input/group/radio/page/picField/label/table/check; команда — отд. путь, §7)
	@{ Tag='Shortcut';              Key='shortcut';              Kind='value' }
	# Батч простых скаляров (input/radio/group/picDecoration/button): режим выбора незаполненного,
	# равная ширина колонок, выравнивание детей, масштаб/зум картинки, форма/положение картинки кнопки.
	# (Table HeaderHeight/FooterHeight/CurrentRowUse — НЕ здесь, а в Emit-Table: pass-through,
	#  1С толерантна к порядку детей Table — в корпусе те же теги встречаются в разных позициях.)
	@{ Tag='IncompleteChoiceMode';  Key='incompleteChoiceMode';  Kind='value' }
	@{ Tag='EqualColumnsWidth';     Key='equalColumnsWidth';     Kind='bool'  }
	@{ Tag='ChildrenAlign';         Key='childrenAlign';         Kind='value' }
	@{ Tag='ImageScale';            Key='imageScale';            Kind='value' }
	@{ Tag='Zoomable';              Key='zoomable';              Kind='bool'  }
	@{ Tag='Shape';                 Key='shape';                 Kind='value' }
	@{ Tag='PictureLocation';       Key='pictureLocation';       Kind='value' }
	# Равная ширина элементов (check/radio) / высота заголовка пункта (radio)
	@{ Tag='EqualItemsWidth';       Key='equalItemsWidth';       Kind='bool'  }
	@{ Tag='ItemTitleHeight';       Key='itemTitleHeight';       Kind='value' }
	# Спец-режим ввода текста (input, моб.: Email/PhoneNumber/...) — листовой enum-скаляр
	@{ Tag='SpecialTextInputMode';  Key='specialTextInputMode';  Kind='value' }
	# Ширина пункта (radio/check) / выбор нескольких значений из выпадающего (input)
	@{ Tag='ItemWidth';                    Key='itemWidth';                    Kind='value' }
	@{ Tag='ShowCheckBoxesInDropList';     Key='showCheckBoxesInDropList';     Kind='bool'  }
	@{ Tag='MultipleValueDataPath';        Key='multipleValueDataPath';        Kind='value' }
	@{ Tag='MultipleValuePresentDataPath'; Key='multipleValuePresentDataPath'; Kind='value' }
	# Режим авто-показа кнопок открытия/очистки (input, enum Auto/Always/FilledOnly/…)
	@{ Tag='AutoShowOpenButtonMode';       Key='autoShowOpenButtonMode';       Kind='value' }
	@{ Tag='AutoShowClearButtonMode';      Key='autoShowClearButtonMode';      Kind='value' }
	# Оформление/картинка множественного выбора (input, редко; цвета — текст-контент, не атрибуты)
	@{ Tag='MultipleValuesTextColor';      Key='multipleValuesTextColor';      Kind='value' }
	@{ Tag='MultipleValuesBackColor';      Key='multipleValuesBackColor';      Kind='value' }
	@{ Tag='MultipleValuePictureShape';    Key='multipleValuePictureShape';    Kind='value' }
	@{ Tag='MultipleValuePictureDataPath'; Key='multipleValuePictureDataPath'; Kind='value' }
	# Хвост листовых скаляров (по 1 в корпусе): автокоррекция ввода (input) / уникальность команды
	# (button) / допуск пустого множ. значения (input) / поведение при гориз. сжатии (table)
	@{ Tag='AutoCorrectionOnTextInput';    Key='autoCorrectionOnTextInput';    Kind='value' }
	@{ Tag='SpellCheckingOnTextInput';     Key='spellCheckingOnTextInput';     Kind='value' }
	@{ Tag='CommandUniqueness';            Key='commandUniqueness';            Kind='bool'  }
	@{ Tag='AllowInputEmptyMultipleValues';Key='allowInputEmptyMultipleValues';Kind='bool'  }
	@{ Tag='BehaviorOnHorizontalCompression'; Key='behaviorOnHorizontalCompression'; Kind='value' }
)

$script:refRootSynonyms = @{
	"Перечисление"            = "Enum"
	"Справочник"              = "Catalog"
	"Документ"                = "Document"
	"ПланСчетов"              = "ChartOfAccounts"
	"ПланВидовХарактеристик"  = "ChartOfCharacteristicTypes"
	"ПланВидовРасчета"        = "ChartOfCalculationTypes"
	"ПланВидовРасчёта"        = "ChartOfCalculationTypes"
	"ПланОбмена"              = "ExchangePlan"
	"БизнесПроцесс"           = "BusinessProcess"
	"Задача"                  = "Task"
	"РегистрСведений"         = "InformationRegister"
	"РегистрНакопления"       = "AccumulationRegister"
	"РегистрБухгалтерии"      = "AccountingRegister"
	"РегистрРасчета"          = "CalculationRegister"
	"РегистрРасчёта"          = "CalculationRegister"
	"ЖурналДокументов"        = "DocumentJournal"
	"КритерийОтбора"          = "FilterCriterion"
}

$script:enumValueSynonyms = @("EnumValue","ЗначениеПеречисления")

function Assert-UniqueName {
	param([string]$name, [hashtable]$seen, [string]$kind)
	if ($seen.ContainsKey($name)) {
		Write-Error "Duplicate $kind name '$name' — names must be unique within their collection in a 1C form (set a unique 'name')"
		exit 1
	}
	$seen[$name] = $true
}

function Esc-Xml {
	param([string]$s)
	# Эскейп ЗНАЧЕНИЯ АТРИБУТА: & < > и кавычка — внутри "..." литеральная " невалидна.
	return $s.Replace('&','&amp;').Replace('<','&lt;').Replace('>','&gt;').Replace('"','&quot;')
}

function Esc-XmlText {
	# Экранирование ТЕКСТА элемента (<v8:content>, <Value>): только & < > .
	# Кавычки/апострофы в тексте экранировать НЕ нужно (1С их не экранирует — пишет литерально);
	# &quot; ломал бы раундтрип. Кавычки спецсимвольны лишь в значениях атрибутов.
	param([string]$s)
	return $s.Replace('&','&amp;').Replace('<','&lt;').Replace('>','&gt;')
}

function Emit-MLItems {
	param($val, [string]$indent)
	if ($val -is [System.Collections.IDictionary]) {
		foreach ($k in $val.Keys) {
			X "$indent<v8:item>"; X "$indent`t<v8:lang>$k</v8:lang>"; X "$indent`t<v8:content>$(Esc-XmlText "$($val[$k])")</v8:content>"; X "$indent</v8:item>"
		}
	} elseif ($val -is [System.Management.Automation.PSCustomObject]) {
		foreach ($p in $val.PSObject.Properties) {
			X "$indent<v8:item>"; X "$indent`t<v8:lang>$($p.Name)</v8:lang>"; X "$indent`t<v8:content>$(Esc-XmlText "$($p.Value)")</v8:content>"; X "$indent</v8:item>"
		}
	} else {
		X "$indent<v8:item>"; X "$indent`t<v8:lang>ru</v8:lang>"; X "$indent`t<v8:content>$(Esc-XmlText "$val")</v8:content>"; X "$indent</v8:item>"
	}
}

function Emit-MLText {
	param([string]$tag, $text, [string]$indent, [string]$xsiType)
	$attr = if ($xsiType) { " xsi:type=`"$xsiType`"" } else { "" }
	X "$indent<$tag$attr>"
	Emit-MLItems -val $text -indent "$indent`t"
	X "$indent</$tag>"
}

function Test-HasRealMarkup {
	param($text)
	if ($null -eq $text) { return $false }
	$vals = if ($text -is [System.Collections.IDictionary]) { @($text.Values) }
		elseif ($text -is [System.Management.Automation.PSCustomObject]) { @($text.PSObject.Properties.Value) }
		else { @("$text") }
	foreach ($v in $vals) { if ("$v" -match $script:fmtMarkupRe) { return $true } }
	return $false
}

function Resolve-MLFormatted {
	param($val)
	$hasText = $false
	if ($val -is [System.Management.Automation.PSCustomObject]) { $hasText = [bool]$val.PSObject.Properties['text'] }
	elseif ($val -is [System.Collections.IDictionary]) { $hasText = $val.Contains('text') }
	if ($hasText) {
		$t = if ($val -is [System.Collections.IDictionary]) { $val['text'] } else { $val.text }
		$f = if ($val -is [System.Collections.IDictionary]) { $val['formatted'] } else { $val.formatted }
		return @{ text = $t; formatted = [bool]$f }
	}
	return @{ text = $val; formatted = (Test-HasRealMarkup $val) }
}

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
	# $tag/$tagAttrs — обёртка (по умолчанию <Type>); для уточнения типа значений ValueList
	# вызывается с tag="Settings", tagAttrs=' xsi:type="v8:TypeDescription"'.
	param($typeStr, [string]$indent, [string]$tag = "Type", [string]$tagAttrs = "")

	if (-not $typeStr) {
		X "$indent<$tag$tagAttrs/>"
		return
	}

	$typeString = "$typeStr"

	# Composite type: "Type1 | Type2" or "Type1 + Type2"
	$parts = $typeString -split '\s*[|+]\s*'

	X "$indent<$tag$tagAttrs>"
	foreach ($part in $parts) {
		$part = $part.Trim()
		Emit-SingleType -typeStr $part -indent "$indent`t"
	}
	X "$indent</$tag>"
}

function Emit-SingleType {
	param([string]$typeStr, [string]$indent)

	$typeStr = Resolve-TypeStr $typeStr

	# TypeId — тип, заданный глобальным стабильным GUID (<v8:TypeId>, не <v8:Type>). Платформа так
	# сериализует типы, чьё имя в этом контексте недоступно (определяемые/характеристики). GUID
	# глобально стабилен → эмитим verbatim (как роль-по-GUID). Маркер декомпилятора: 'typeid:GUID'.
	if ($typeStr -match '^typeid:([0-9a-fA-F-]{36})$') {
		X "$indent<v8:TypeId>$($Matches[1])</v8:TypeId>"
		return
	}

	# boolean
	if ($typeStr -eq "boolean") {
		X "$indent<v8:Type>xs:boolean</v8:Type>"
		return
	}

	# string or string(N) or string(N,fixed) (AllowedLength: Variable дефолт / Fixed)
	if ($typeStr -match '^string(\((\d+)(\s*,\s*(fixed|variable))?\))?$') {
		$len = if ($Matches[2]) { $Matches[2] } else { "0" }
		$al = if ($Matches[4] -and $Matches[4].ToLower() -eq 'fixed') { 'Fixed' } else { 'Variable' }
		X "$indent<v8:Type>xs:string</v8:Type>"
		X "$indent<v8:StringQualifiers>"
		X "$indent`t<v8:Length>$len</v8:Length>"
		X "$indent`t<v8:AllowedLength>$al</v8:AllowedLength>"
		X "$indent</v8:StringQualifiers>"
		return
	}

	# decimal(D,F) or decimal(D,F,nonneg)
	if ($typeStr -match '^decimal\((\d+),(\d+)(,nonneg)?\)$') {
		$digits = $Matches[1]
		$fraction = $Matches[2]
		$sign = if ($Matches[3]) { "Nonnegative" } else { "Any" }
		X "$indent<v8:Type>xs:decimal</v8:Type>"
		X "$indent<v8:NumberQualifiers>"
		X "$indent`t<v8:Digits>$digits</v8:Digits>"
		X "$indent`t<v8:FractionDigits>$fraction</v8:FractionDigits>"
		X "$indent`t<v8:AllowedSign>$sign</v8:AllowedSign>"
		X "$indent</v8:NumberQualifiers>"
		return
	}

	# date / dateTime / time
	if ($typeStr -match '^(date|dateTime|time)$') {
		$fractions = switch ($typeStr) {
			"date"     { "Date" }
			"dateTime" { "DateTime" }
			"time"     { "Time" }
		}
		X "$indent<v8:Type>xs:dateTime</v8:Type>"
		X "$indent<v8:DateQualifiers>"
		X "$indent`t<v8:DateFractions>$fractions</v8:DateFractions>"
		X "$indent</v8:DateQualifiers>"
		return
	}

	# ValueTable, ValueTree, ValueList, etc.
	$v8Types = @{
		"ValueTable"       = "v8:ValueTable"
		"ValueTree"        = "v8:ValueTree"
		"ValueList"        = "v8:ValueListType"
		"TypeDescription"  = "v8:TypeDescription"
		"Universal"        = "v8:Universal"
		"FixedArray"       = "v8:FixedArray"
		"FixedStructure"   = "v8:FixedStructure"
	}
	if ($v8Types.ContainsKey($typeStr)) {
		X "$indent<v8:Type>$($v8Types[$typeStr])</v8:Type>"
		return
	}

	# UI types
	$uiTypes = @{
		"FormattedString" = "v8ui:FormattedString"
		"Picture"         = "v8ui:Picture"
		"Color"           = "v8ui:Color"
		"Font"            = "v8ui:Font"
	}
	if ($uiTypes.ContainsKey($typeStr)) {
		X "$indent<v8:Type>$($uiTypes[$typeStr])</v8:Type>"
		return
	}

	# DCS types
	if ($typeStr -match '^DataComposition') {
		$dcsMap = @{
			"DataCompositionSettings"      = "dcsset:DataCompositionSettings"
			"DataCompositionSchema"        = "dcssch:DataCompositionSchema"
			"DataCompositionComparisonType" = "dcscor:DataCompositionComparisonType"
		}
		if ($dcsMap.ContainsKey($typeStr)) {
			X "$indent<v8:Type>$($dcsMap[$typeStr])</v8:Type>"
			return
		}
	}

	# Голые конфигурационные типы (cfg: без .Имя): дин-список, набор констант, общий объект отчёта.
	# Корпус (acc+erp 8.3.24): DynamicList 5205, ConstantsSet 103, ReportObject 10. (Дотированные формы
	# ConstantsSet.X / ReportObject.X ловит общий cfg:-regex ниже.)
	if ($typeStr -in @("DynamicList","ConstantsSet","ReportObject")) {
		X "$indent<v8:Type>cfg:$typeStr</v8:Type>"
		return
	}

	# TypeSet (набор типов) → <v8:TypeSet>: определяемый тип / характеристика (именованные)
	# + «любая ссылка вида» (голый ref-вид без .Имя). Развязка с обычным типом — по наличию точки.
	if ($typeStr -match '^(DefinedType|Characteristic)\.') {
		X "$indent<v8:TypeSet>cfg:$typeStr</v8:TypeSet>"
		return
	}
	if ($typeStr -match '^(AnyRef|AnyIBRef|CatalogRef|DocumentRef|EnumRef|ExchangePlanRef|TaskRef|BusinessProcessRef|ChartOfAccountsRef|ChartOfCharacteristicTypesRef|ChartOfCalculationTypesRef)$') {
		X "$indent<v8:TypeSet>cfg:$typeStr</v8:TypeSet>"
		return
	}

	# cfg: references (CatalogRef.XXX, DocumentObject.XXX, etc.)
	if ($typeStr -match '^(CatalogRef|CatalogObject|DocumentRef|DocumentObject|EnumRef|ChartOfAccountsRef|ChartOfAccountsObject|ChartOfCharacteristicTypesRef|ChartOfCharacteristicTypesObject|ChartOfCalculationTypesRef|ChartOfCalculationTypesObject|ExchangePlanRef|ExchangePlanObject|BusinessProcessRef|BusinessProcessObject|TaskRef|TaskObject|InformationRegisterRecordSet|InformationRegisterRecordManager|AccumulationRegisterRecordSet|AccountingRegisterRecordSet|ConstantsSet|DataProcessorObject|ReportObject)\.') {
		X "$indent<v8:Type>cfg:$typeStr</v8:Type>"
		return
	}

	# Спец-типы платформы с собственным namespace (объявляется ЛОКАЛЬНО на <v8:Type>).
	# Префикс d5p1 неоднозначен (5 разных URI), поэтому маппинг по полному значению типа.
	# К таким типам привязаны спец-поля: mxl→SpreadSheetDocumentField, fd→FormattedDocumentField,
	# d5p1:TextDocument→TextDocumentField, pdfdoc→PDF, pl→Planner, chart/geo/graphscheme/data-analysis.
	$specialTypeNs = @{
		"mxl:SpreadsheetDocument"               = "http://v8.1c.ru/8.2/data/spreadsheet"
		"fd:FormattedDocument"                  = "http://v8.1c.ru/8.2/data/formatted-document"
		"d5p1:TextDocument"                     = "http://v8.1c.ru/8.1/data/txtedt"
		"d5p1:Chart"                            = "http://v8.1c.ru/8.2/data/chart"
		"d5p1:GanttChart"                       = "http://v8.1c.ru/8.2/data/chart"
		"d5p1:Dendrogram"                       = "http://v8.1c.ru/8.2/data/chart"
		"d5p1:FlowchartContextType"             = "http://v8.1c.ru/8.2/data/graphscheme"
		"d5p1:DataAnalysisTimeIntervalUnitType" = "http://v8.1c.ru/8.2/data/data-analysis"
		"d5p1:GeographicalSchema"               = "http://v8.1c.ru/8.2/data/geo"
		"pdfdoc:PDFDocument"                    = "http://v8.1c.ru/8.3/data/pdf"
		"pl:Planner"                            = "http://v8.1c.ru/8.3/data/planner"
	}
	if ($specialTypeNs.ContainsKey($typeStr)) {
		$pref = $typeStr.Substring(0, $typeStr.IndexOf(':'))
		X "$indent<v8:Type xmlns:$pref=`"$($specialTypeNs[$typeStr])`">$typeStr</v8:Type>"
		return
	}

	# Fallback with validation
	if ($script:knownInvalidTypes.ContainsKey($typeStr)) {
		throw "Invalid form attribute type '$typeStr': $($script:knownInvalidTypes[$typeStr])"
	}
	# Платформенный тип с префиксом (v8:/v8ui:/xs:/dcs*:) — эмитим verbatim (напр. v8:UUID, v8:StandardPeriod).
	if ($typeStr -match '^(v8|v8ui|xs|ent|style|sys|web|win|dcs\w*):') {
		X "$indent<v8:Type>$typeStr</v8:Type>"
	} elseif ($typeStr.Contains('.')) {
		X "$indent<v8:Type>cfg:$typeStr</v8:Type>"
	} else {
		Write-Warning "Unrecognized bare type '$typeStr' — will be emitted without namespace prefix"
		X "$indent<v8:Type>$typeStr</v8:Type>"
	}
}

function Get-HandlerName {
	param([string]$elementName, [string]$eventName)
	$suffix = $script:eventSuffixMap[$eventName]
	if ($suffix) {
		return "$elementName$suffix"
	}
	return "$elementName$eventName"
}

function Get-ElementName {
	param($el, [string]$typeKey)
	if ($el.name) { return "$($el.name)" }
	return "$($el.$typeKey)"
}

function Get-EventPairs {
	param($el, [string]$elementName)
	$pairs = New-Object System.Collections.ArrayList
	if ($el.events) {
		foreach ($p in $el.events.PSObject.Properties) {
			# Значение — имя обработчика; null — имя по шаблону; объект { handler, callType } или массив
			# таких объектов (в расширении на одно событие вешают и Before, и After)
			$vals = @($p.Value)   # массив — как есть, одно значение (в т.ч. null) — один элемент
			foreach ($v in $vals) {
				$h = ""; $ct = ""
				if ($v -is [System.Management.Automation.PSCustomObject]) { $h = "$($v.handler)"; $ct = Normalize-CallType "$($v.callType)" $elementName $p.Name } else { $h = "$v" }
				if ([string]::IsNullOrEmpty($h)) { $h = Get-HandlerName -elementName $elementName -eventName $p.Name }
				[void]$pairs.Add([pscustomobject]@{ name = $p.Name; handler = $h; callType = $ct })
			}
		}
	} elseif ($el.on) {
		foreach ($evt in $el.on) {
			if ($evt -is [System.Management.Automation.PSCustomObject]) {
				$evtName = "$($evt.event)"; $h = "$($evt.handler)"; $ct = Normalize-CallType "$($evt.callType)" $elementName $evtName
			} else {
				$evtName = "$evt"; $h = ""; $ct = ""
			}
			if (-not $h) { $h = if ($el.handlers -and $el.handlers.$evtName) { "$($el.handlers.$evtName)" } else { Get-HandlerName -elementName $elementName -eventName $evtName } }
			[void]$pairs.Add([pscustomobject]@{ name = $evtName; handler = $h; callType = $ct })
		}
	}
	return $pairs
}

function Normalize-CallType([string]$raw, [string]$elementName, [string]$eventName) {
	if ([string]::IsNullOrEmpty($raw)) { return '' }
	foreach ($v in @('Before','After','Override')) { if ($raw -eq $v) { return $v } }
	Write-Error "Element '$elementName', event '$eventName': callType '$raw' — expected Before, After or Override"
	exit 1
}

function Emit-Events {
	param($el, [string]$elementName, [string]$indent, [string]$typeKey)

	$pairs = Get-EventPairs -el $el -elementName $elementName
	if ($pairs.Count -eq 0) { return }

	# Validate event names
	if ($typeKey -and $script:knownEvents.ContainsKey($typeKey)) {
		$allowed = $script:knownEvents[$typeKey]
		foreach ($pr in $pairs) {
			if ($allowed.Count -gt 0 -and $allowed -notcontains "$($pr.name)") {
				Write-Host "[WARN] Unknown event '$($pr.name)' for $typeKey '$elementName'. Known: $($allowed -join ', ')"
			}
		}
	}

	X "$indent<Events>"
	foreach ($pr in $pairs) {
		$ctAttr = if ($pr.callType) { " callType=`"$($pr.callType)`"" } else { "" }
		X "$indent`t<Event name=`"$($pr.name)`"$ctAttr>$($pr.handler)</Event>"
	}
	X "$indent</Events>"
}

function Test-CompanionStructured {
	param($content)
	if (-not (($content -is [System.Collections.IDictionary]) -or ($content -is [System.Management.Automation.PSCustomObject]))) { return $false }
	foreach ($k in $script:companionStructKeys) {
		$present = if ($content -is [System.Collections.IDictionary]) { $content.Contains($k) } else { [bool]$content.PSObject.Properties[$k] }
		if ($present) { return $true }
	}
	return $false
}

function Emit-CompanionTitle {
	param($content, [string]$indent)
	$r = Resolve-MLFormatted $content
	$fmt = if ($r.formatted) { 'true' } else { 'false' }
	X "$indent<Title formatted=`"$fmt`">"
	Emit-MLItems -val $r.text -indent "$indent`t"
	X "$indent</Title>"
}

function DI-Attr {
	param($el)
	if ($null -ne $el -and $el.displayImportance) { return " DisplayImportance=`"$(Esc-Xml "$($el.displayImportance)")`"" }
	return ""
}

function Emit-Companion {
	param([string]$tag, [string]$name, [string]$indent, $content = $null)
	$id = New-Id
	$hasContent = $null -ne $content -and -not ($content -is [string] -and "$content" -eq '')
	if (-not $hasContent) {
		X "$indent<$tag name=`"$name`" id=`"$id`"/>"
		return
	}
	$inner = "$indent`t"
	# DI-Attr берём от СОБСТВЕННОГО объекта компаньона ($content), НЕ от ambient $el родителя
	# (PowerShell dynamic scope — иначе companion наследует DisplayImportance владельца: баг).
	X "$indent<$tag name=`"$name`" id=`"$id`"$(DI-Attr $content)>"
	if (Test-CompanionStructured $content) {
		# структурированная форма (own-content). Порядок как у платформы: own-content (флаги/hyperlink/
		# layout/оформление) ПЕРЕД Title (в корпусе layout-first 582 vs 10).
		$txtPresent = if ($content -is [System.Collections.IDictionary]) { $content.Contains('text') } else { [bool]$content.PSObject.Properties['text'] }
		Emit-CommonFlags -el $content -indent $inner
		if ($content.hyperlink -eq $true) { X "$inner<Hyperlink>true</Hyperlink>" }
		Emit-Layout -el $content -indent $inner
		Emit-Appearance -el $content -indent $inner -profile 'decoration'
		if ($txtPresent) { Emit-CompanionTitle -content $content -indent $inner }
		# ToolTip компаньона (подсказка самой расширенной подсказки) — после Title (порядок схемы LabelDecoration)
		if ($content.tooltip) { Emit-MLText -tag "ToolTip" -text $content.tooltip -indent $inner }
		# События компаньона (ExtendedTooltip = LabelDecoration: напр. URLProcessing у hyperlink-подсказки)
		Emit-Events -el $content -elementName $name -indent $inner -typeKey 'label'
	} else {
		Emit-CompanionTitle -content $content -indent $inner
	}
	X "$indent</$tag>"
}

function Emit-CompanionPanel {
	param([string]$tag, [string]$name, [string]$indent, $panel)
	$id = New-Id
	$autofill = $null
	$children = $null
	$halign = $null
	if ($panel -is [array]) {
		$children = $panel
	} elseif ($null -ne $panel) {
		if ($null -ne $panel.PSObject.Properties['autofill'] -and $null -ne $panel.autofill) { $autofill = [bool]$panel.autofill }
		if ($null -ne $panel.PSObject.Properties['horizontalAlign'] -and "$($panel.horizontalAlign)" -ne '') { $halign = "$($panel.horizontalAlign)" }
		$children = $panel.children
	}
	$hasChildren = $children -and @($children).Count -gt 0
	# Платформа пишет <Autofill> только при false; true = дефолт (тег опускается).
	$emitAfFalse = ($autofill -eq $false)
	if (-not $emitAfFalse -and -not $hasChildren -and -not $halign) {
		X "$indent<$tag name=`"$name`" id=`"$id`"/>"
		return
	}
	X "$indent<$tag name=`"$name`" id=`"$id`"$(DI-Attr $panel)>"
	if ($halign) { X "$indent`t<HorizontalAlign>$halign</HorizontalAlign>" }
	if ($emitAfFalse) { X "$indent`t<Autofill>false</Autofill>" }
	if ($hasChildren) {
		X "$indent`t<ChildItems>"
		foreach ($c in @($children)) { Emit-Element -el $c -indent "$indent`t`t" -inCmdBar $true }
		X "$indent`t</ChildItems>"
	}
	X "$indent</$tag>"
}

function Get-HLocation {
	param($el)
	$v = if ($el -and $el.PSObject.Properties['horizontalLocation']) { $el.horizontalLocation } else { $null }
	if (-not $v) { return $null }
	switch -Regex ("$v".ToLower()) {
		'^(auto|авто)$'          { return $null }    # дефолт — не эмитим
		'^(left|слева|лево)$'    { return 'Left' }
		'^(right|справа|право)$'  { return 'Right' }
		'^(center|центр|по центру)$' { return 'Center' }
		default                  { return "$v" }
	}
}

function Emit-AdditionBody {
	param($props, [string]$source, [string]$srcType, [string]$addName, [string]$indent)
	$inner = "$indent`t"
	X "$inner<AdditionSource>"
	X "$inner`t<Item>$source</Item>"
	X "$inner`t<Type>$srcType</Type>"
	X "$inner</AdditionSource>"
	if ($props) {
		if ($props.PSObject.Properties['title'] -and $props.title) { Emit-MLText -tag "Title" -text $props.title -indent $inner }
		Emit-CommonFlags -el $props -indent $inner
		if ($props.tooltip) { Emit-MLText -tag "ToolTip" -text $props.tooltip -indent $inner }
		if ($props.tooltipRepresentation) { X "$inner<ToolTipRepresentation>$($props.tooltipRepresentation)</ToolTipRepresentation>" }
		$hl = Get-HLocation $props; if ($hl) { X "$inner<HorizontalLocation>$hl</HorizontalLocation>" }
		Emit-Layout -el $props -indent $inner
		Emit-Appearance -el $props -indent $inner -profile 'field'
	}
	Emit-Companion -tag "ContextMenu" -name "${addName}КонтекстноеМеню" -indent $inner
	Emit-Companion -tag "ExtendedTooltip" -name "${addName}РасширеннаяПодсказка" -indent $inner
}

function Emit-Addition {
	param($el, [string]$name, [int]$id, [string]$typeKey, [string]$indent)
	$map = $script:additionTypeMap[$typeKey]
	$source = if ($el.source) { "$($el.source)" } elseif ($script:currentTableName) { $script:currentTableName } else { '' }
	X "$indent<$($map.Tag) name=`"$name`" id=`"$id`"$(DI-Attr $el)>"
	Emit-AdditionBody -props $el -source $source -srcType $map.Type -addName $name -indent $indent
	X "$indent</$($map.Tag)>"
}

function Emit-TableAddition {
	param([string]$typeKey, [string]$tableName, [string]$indent, $override = $null)
	$map = $script:additionTypeMap[$typeKey]
	$addName = "$tableName$($map.Suffix)"
	$id = New-Id
	X "$indent<$($map.Tag) name=`"$addName`" id=`"$id`">"
	Emit-AdditionBody -props $override -source $tableName -srcType $map.Type -addName $addName -indent $indent
	X "$indent</$($map.Tag)>"
}

function Get-AdditionOverride {
	param($additions, [string]$typeKey)
	if ($null -eq $additions) { return $null }
	foreach ($k in @($typeKey) + $script:additionKeySynonyms[$typeKey]) {
		$p = $additions.PSObject.Properties[$k]
		if ($p) { return $p.Value }
	}
	return $null
}

function Normalize-ElementTypeSynonyms {
	param($el)
	foreach ($pair in $script:elementTypeSynonyms.GetEnumerator()) {
		if ($null -ne $el.PSObject.Properties[$pair.Key] -and $null -eq $el.PSObject.Properties[$pair.Value]) {
			if ($script:elementTypeStrOnlyKeys -contains $pair.Key -and -not ($el.($pair.Key) -is [string])) { continue }
			$val = $el.($pair.Key)
			$el.PSObject.Properties.Remove($pair.Key) | Out-Null
			$el | Add-Member -NotePropertyName $pair.Value -NotePropertyValue $val -Force
		}
	}
}

function Emit-Element {
	param($el, [string]$indent, [bool]$inCmdBar = $false)

	# Companion-панели (объект/массив-значение) → commandBar/contextMenu, до тип-синонимов.
	Normalize-PanelSynonyms $el

	# Синонимы типа (XML-имя, русское имя) → канонический ключ DSL
	Normalize-ElementTypeSynonyms $el

	# Синонимы ключей-свойств (русские имена 1С → канон. англ.). Case/space-insensitive.
	# Канон побеждает: если задан и русский, и англ. ключ — англ. остаётся, русский отбрасываем.
	foreach ($pn in @($el.PSObject.Properties.Name)) {
		$norm = ($pn -replace '\s','').ToLower()
		$canon = $script:propSynonyms[$norm]
		if ($canon -and $pn -ne $canon) {
			if ($null -eq $el.PSObject.Properties[$canon]) {
				$val = $el.($pn)
				$el | Add-Member -NotePropertyName $canon -NotePropertyValue $val -Force
			}
			$el.PSObject.Properties.Remove($pn) | Out-Null
		}
	}

	# Determine element type from key
	$typeKey = $null
	$xmlTag = $null

	# picture/picField — НИЗКИЙ приоритет: 'picture' это и тип (PictureDecoration), и свойство-иконка
	# у popup/button/cmdBar. Тип-ключ владельца (popup/button/…) должен выиграть.
	# pages/page ПЕРЕД group: у Page/Pages ключ 'group' — это направление раскладки детей
	# (<Group>Horizontal</Group>), а не тип UsualGroup. Реальная UsualGroup ключа page/pages не несёт.
	foreach ($key in @("columnGroup","buttonGroup","pages","page","group","input","check","radio","label","labelField","table","button","calendar","cmdBar","popup","searchString","viewStatus","searchControl","picField","picture","spreadsheet","html","textDoc","formattedDoc","progressBar","trackBar","chart","ganttChart","graphicalSchema","planner","periodField","dendrogram")) {
		if ($el.$key -ne $null) {
			$typeKey = $key
			break
		}
	}

	if (-not $typeKey) {
		Write-Warning "Unknown element type, skipping"
		return
	}

	# Validate known keys — warn about typos and unknown properties
	$knownKeys = @{
		# type keys
		"group"=1;"columnGroup"=1;"buttonGroup"=1;"input"=1;"check"=1;"radio"=1;"label"=1;"labelField"=1;"table"=1;"pages"=1;"page"=1
		"button"=1;"picture"=1;"picField"=1;"calendar"=1;"cmdBar"=1;"popup"=1
		# спец-поля (документ/датчик/диаграмма) — тип-ключи + типоспец. скаляры
		"spreadsheet"=1;"html"=1;"textDoc"=1;"formattedDoc"=1;"progressBar"=1;"trackBar"=1
		"chart"=1;"ganttChart"=1;"graphicalSchema"=1;"planner"=1;"periodField"=1;"dendrogram"=1;"ganttTable"=1
		"showPercent"=1;"largeStep"=1;"markingStep"=1;"step"=1
		"horizontalScrollBar"=1;"viewScalingMode"=1;"output"=1;"selectionShowMode"=1;"protection"=1
		"edit"=1;"showGrid"=1;"showGroups"=1;"showHeaders"=1;"showRowAndColumnNames"=1;"showCellNames"=1
		"pointerType"=1;"drawingSelectionShowMode"=1;"warningOnEditRepresentation"=1;"markingAppearance"=1
		# report-form контекст (generic-скаляры элементов)
		"horizontalSpacing"=1;"representationInContextMenu"=1;"settingsNamedItemDetailedRepresentation"=1
		# хвост: высота элемента списка / ширина выпадающего списка / картинка кнопки выбора / прозрачный пиксель
		"itemHeight"=1;"dropListWidth"=1;"choiceButtonPicture"=1;"transparentPixel"=1
		# хвост CI-форм: динамический заголовок / расширенное редактирование / высота таблицы
		"titleDataPath"=1;"extendedEdit"=1;"maxRowsCount"=1;"autoMaxRowsCount"=1;"heightControlVariant"=1
		"warningOnEdit"=1;"nonselectedPictureText"=1;"editTextUpdate"=1;"footerText"=1
		# columnGroup-specific
		"showInHeader"=1
		# radio-specific
		"radioButtonType"=1;"choiceList"=1;"columnsCount"=1;"checkBoxType"=1;"editMode"=1
		# naming & binding
		"name"=1;"path"=1;"title"=1;"tooltip"=1;"tooltipRepresentation"=1;"extendedTooltip"=1
		# companion-панели (свойства): командная панель + контекстное меню
		"commandBar"=1;"contextMenu"=1
		# источник команд группы/панели (ButtonGroup/CommandBar)
		"commandSource"=1
		# visibility & state
		"visible"=1;"hidden"=1;"enabled"=1;"disabled"=1;"readOnly"=1;"userVisible"=1
		# events ("events" — основной формат; on/handlers — legacy, принимаются ради совместимости)
		"events"=1;"on"=1;"handlers"=1
		# layout
		"titleLocation"=1;"representation"=1;"width"=1;"height"=1
		"horizontalStretch"=1;"verticalStretch"=1;"autoMaxWidth"=1;"autoMaxHeight"=1
		"maxWidth"=1;"maxHeight"=1
		"groupHorizontalAlign"=1;"groupVerticalAlign"=1;"horizontalAlign"=1
		# input-specific
		"multiLine"=1;"passwordMode"=1;"choiceButton"=1;"clearButton"=1
		"spinButton"=1;"dropListButton"=1;"markIncomplete"=1;"skipOnInput"=1;"inputHint"=1
		"textEdit"=1
		"wrap"=1;"openButton"=1;"listChoiceMode"=1;"showInFooter"=1
		"extendedEditMultipleValues"=1;"chooseType"=1;"autoCellHeight"=1
		"choiceButtonRepresentation"=1;"footerHorizontalAlign"=1;"headerHorizontalAlign"=1
		"headerDataPath"=1;"headerFormat"=1;"currentRowUse"=1
		"format"=1;"editFormat"=1;"choiceParameters"=1;"choiceParameterLinks"=1;"typeLink"=1
		# label/hyperlink
		"hyperlink"=1;"formatted"=1
		# group-specific
		"collapsedTitle"=1;"showTitle"=1;"united"=1;"collapsed"=1;"behavior"=1
		# hierarchy
		"children"=1;"columns"=1
		# table-specific
		"changeRowSet"=1;"changeRowOrder"=1;"autoInsertNewRow"=1;"rowFilter"=1;"header"=1;"footer"=1
		"commandBarLocation"=1;"searchStringLocation"=1;"viewStatusLocation"=1;"searchControlLocation"=1
		"excludedCommands"=1
		"choiceMode"=1;"initialTreeView"=1;"enableDrag"=1;"enableStartDrag"=1
		"rowPictureDataPath"=1;"tableAutofill"=1;"heightInTableRows"=1
		"multipleChoice"=1;"searchOnInput"=1;"shortcut"=1
		"rowSelectionMode"=1;"verticalLines"=1;"horizontalLines"=1
		# dynamic-list table block
		"defaultItem"=1;"useAlternationRowColor"=1;"fileDragMode"=1;"autoRefresh"=1
		"autoRefreshPeriod"=1;"choiceFoldersAndItems"=1;"restoreCurrentRow"=1;"showRoot"=1
		"allowRootChoice"=1;"updateOnDataChange"=1;"allowGettingCurrentRowURL"=1
		"userSettingsGroup"=1;"rowsPicture"=1
		# calendar-specific
		"selectionMode"=1;"showCurrentDate"=1;"widthInMonths"=1;"heightInMonths"=1;"showMonthsPanel"=1
		# pages-specific
		"pagesRepresentation"=1
		# button-specific
		"type"=1;"command"=1;"commandName"=1;"stdCommand"=1;"parameter"=1;"defaultButton"=1;"locationInCommandBar"=1;"displayImportance"=1
		# picture/decoration
		"src"=1;"valuesPicture"=1;"loadTransparent"=1;"headerPicture"=1;"footerPicture"=1
		# cmdBar-specific
		"autofill"=1
		# AutoCommandBar-маркер (autofill heuristic) на элементе/таблице
		"autoCmdBar"=1
		# дополнения командной панели таблицы (тип-ключи + свойства)
		"searchString"=1;"viewStatus"=1;"searchControl"=1;"source"=1;"horizontalLocation"=1;"additions"=1
		# generic-скаляры (pass-through) + точечные
		"verticalAlign"=1;"throughAlign"=1;"enableContentChange"=1;"pictureSize"=1;"titleHeight"=1
		"childItemsWidth"=1;"showLeftMargin"=1;"cellHyperlink"=1;"viewMode"=1;"verticalScrollBar"=1
		"rowInputMode"=1;"mask"=1;"createButton"=1;"fixingInTable"=1;"verticalSpacing"=1
		# InputField choice-скаляры
		"choiceListButton"=1;"quickChoice"=1;"autoChoiceIncomplete"=1
		"choiceForm"=1;"choiceHistoryOnInput"=1;"footerDataPath"=1;"minValue"=1;"maxValue"=1
		# Button — пометка toggle-кнопки (ключ 'checked', не 'check' — во избежание конфликта с типом)
		"checked"=1
	}
	# Оформление (цвета/шрифты/граница) — авто-регистрация из самих структур, чтобы allowlist
	# не дрейфовал при добавлении новых ключей/синонимов. Канонические + forgiving-синонимы.
	foreach ($k in $script:appearanceSpec.Keys)     { $knownKeys[$k] = 1 }
	foreach ($k in $script:appearanceSynonyms.Keys) { $knownKeys[$k] = 1 }
	foreach ($k in $script:propSynonyms.Keys)       { $knownKeys[$k] = 1 }
	# Простые скаляры (pass-through) — тоже из своей таблицы: компилятор их выводит, значит, они известны
	foreach ($g in $script:genericScalars)          { $knownKeys[$g.Key] = 1 }
	foreach ($p in $el.PSObject.Properties) {
		if ($p.Name -like '_*') { continue }  # внутренние маркеры (напр. _dynList)
		if (-not $knownKeys.ContainsKey($p.Name)) {
			Write-Warning "Element '$($el.$typeKey)': unknown key '$($p.Name)' — ignored. Check SKILL.md for valid keys."
		}
	}

	$name = Get-ElementName -el $el -typeKey $typeKey
	Assert-UniqueName -name $name -seen $script:seenElementNames -kind 'element'
	$id = New-Id

	switch ($typeKey) {
		"group"    { Emit-Group -el $el -name $name -id $id -indent $indent }
		"columnGroup" { Emit-ColumnGroup -el $el -name $name -id $id -indent $indent }
		"buttonGroup" { Emit-ButtonGroup -el $el -name $name -id $id -indent $indent }
		"input"    { Emit-Input -el $el -name $name -id $id -indent $indent }
		"check"    { Emit-Check -el $el -name $name -id $id -indent $indent }
		"radio"    { Emit-Radio -el $el -name $name -id $id -indent $indent }
		"label"    { Emit-Label -el $el -name $name -id $id -indent $indent }
		"labelField" { Emit-LabelField -el $el -name $name -id $id -indent $indent }
		"table"    { Emit-Table -el $el -name $name -id $id -indent $indent }
		"pages"    { Emit-Pages -el $el -name $name -id $id -indent $indent }
		"page"     { Emit-Page -el $el -name $name -id $id -indent $indent }
		"button"   { Emit-Button -el $el -name $name -id $id -indent $indent -inCmdBar $inCmdBar }
		"picture"  { Emit-PictureDecoration -el $el -name $name -id $id -indent $indent }
		"searchString"  { Emit-Addition -el $el -name $name -typeKey "searchString"  -id $id -indent $indent }
		"viewStatus"    { Emit-Addition -el $el -name $name -typeKey "viewStatus"    -id $id -indent $indent }
		"searchControl" { Emit-Addition -el $el -name $name -typeKey "searchControl" -id $id -indent $indent }
		"picField" { Emit-PictureField -el $el -name $name -id $id -indent $indent }
		"calendar" { Emit-Calendar -el $el -name $name -id $id -indent $indent }
		"cmdBar"   { Emit-CommandBar -el $el -name $name -id $id -indent $indent }
		"popup"    { Emit-Popup -el $el -name $name -id $id -indent $indent }
		"spreadsheet"  { Emit-SimpleField -el $el -name $name -id $id -indent $indent -xmlTag "SpreadSheetDocumentField" -typeKey "spreadsheet" }
		"html"         { Emit-SimpleField -el $el -name $name -id $id -indent $indent -xmlTag "HTMLDocumentField" -typeKey "html" }
		"textDoc"      { Emit-SimpleField -el $el -name $name -id $id -indent $indent -xmlTag "TextDocumentField" -typeKey "textDoc" }
		"formattedDoc" { Emit-SimpleField -el $el -name $name -id $id -indent $indent -xmlTag "FormattedDocumentField" -typeKey "formattedDoc" }
		"progressBar"  { Emit-SimpleField -el $el -name $name -id $id -indent $indent -xmlTag "ProgressBarField" -typeKey "progressBar" }
		"trackBar"     { Emit-SimpleField -el $el -name $name -id $id -indent $indent -xmlTag "TrackBarField" -typeKey "trackBar" }
		"chart"           { Emit-SimpleField -el $el -name $name -id $id -indent $indent -xmlTag "ChartField" -typeKey "chart" }
		"graphicalSchema" { Emit-SimpleField -el $el -name $name -id $id -indent $indent -xmlTag "GraphicalSchemaField" -typeKey "graphicalSchema" }
		"planner"         { Emit-SimpleField -el $el -name $name -id $id -indent $indent -xmlTag "PlannerField" -typeKey "planner" }
		"periodField"     { Emit-SimpleField -el $el -name $name -id $id -indent $indent -xmlTag "PeriodField" -typeKey "periodField" }
		"dendrogram"      { Emit-SimpleField -el $el -name $name -id $id -indent $indent -xmlTag "DendrogramField" -typeKey "dendrogram" }
		"ganttChart"      { Emit-GanttChart -el $el -name $name -id $id -indent $indent }
	}
}

function Emit-XrFlag {
	param([string]$tag, $val, [string]$indent)
	if ($null -eq $val) { return }
	if ($val -is [bool]) {
		X "$indent<$tag>"
		X "$indent`t<xr:Common>$(if ($val){'true'}else{'false'})</xr:Common>"
		X "$indent</$tag>"
		return
	}
	# объектная форма { common, roles }
	$common = if ($null -ne $val.common) { [bool]$val.common } else { $false }
	X "$indent<$tag>"
	X "$indent`t<xr:Common>$(if ($common){'true'}else{'false'})</xr:Common>"
	if ($val.roles) {
		foreach ($r in $val.roles.PSObject.Properties) {
			# Forgiving: принимаем имя без префикса, с "Role." или кириллическим "Роль." → нормализуем в "Role.".
			# Роль по GUID (заимствованная/расширение — name="<guid>" без префикса) эмитим как есть.
			$rname = "$($r.Name)" -replace '^(Role|Роль)\.', ''
			if ($rname -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') { $rname = "Role.$rname" }
			$rval = if ([bool]$r.Value) { 'true' } else { 'false' }
			X "$indent`t<xr:Value name=`"$rname`">$rval</xr:Value>"
		}
	}
	X "$indent</$tag>"
}

function Emit-CommonFlags {
	param($el, [string]$indent)
	if ($el.visible -eq $false -or $el.hidden -eq $true) { X "$indent<Visible>false</Visible>" }
	if ($null -ne $el.userVisible) { Emit-XrFlag -tag 'UserVisible' -val $el.userVisible -indent $indent }
	if ($el.enabled -eq $false -or $el.disabled -eq $true) { X "$indent<Enabled>false</Enabled>" }
	if ($el.readOnly -eq $true) { X "$indent<ReadOnly>true</ReadOnly>" }
}

function Emit-CommonElementProps {
	param($el, [string]$indent)
	if ($el.defaultItem -eq $true) { X "$indent<DefaultItem>true</DefaultItem>" }
	if ($el.PSObject.Properties['skipOnInput'] -and $null -ne $el.skipOnInput) {
		$siv = if ($el.skipOnInput -eq $true) { 'true' } else { 'false' }
		X "$indent<SkipOnInput>$siv</SkipOnInput>"
	}
	# EnableStartDrag — фактическое значение (платформа эмитит и явный false, напр. SpreadSheet)
	if ($null -ne $el.enableStartDrag) { X "$indent<EnableStartDrag>$(if ($el.enableStartDrag){'true'}else{'false'})</EnableStartDrag>" }
	if ($el.fileDragMode) { X "$indent<FileDragMode>$($el.fileDragMode)</FileDragMode>" }
	# Cell-свойства поля в таблице (общие для Input/Label/Picture/CheckBox): захват «как есть»
	foreach ($p in @(@('showInHeader','ShowInHeader'), @('showInFooter','ShowInFooter'), @('autoCellHeight','AutoCellHeight'))) {
		if ($null -ne $el.($p[0])) { X "$indent<$($p[1])>$(if ($el.($p[0])){'true'}else{'false'})</$($p[1])>" }
	}
	# Динамический заголовок колонки-группы из данных (HeaderDataPath) — перед HeaderHorizontalAlign (порядок XSD)
	if ($el.headerDataPath) { X "$indent<HeaderDataPath>$(Esc-XmlText "$($el.headerDataPath)")</HeaderDataPath>" }
	if ($el.footerHorizontalAlign) { X "$indent<FooterHorizontalAlign>$($el.footerHorizontalAlign)</FooterHorizontalAlign>" }
	if ($el.headerHorizontalAlign) { X "$indent<HeaderHorizontalAlign>$($el.headerHorizontalAlign)</HeaderHorizontalAlign>" }
	# Формат заголовка колонки-группы (ML-текст) — после HeaderHorizontalAlign (порядок XSD)
	if ($el.headerFormat) { Emit-MLText -tag "HeaderFormat" -text $el.headerFormat -indent $indent }
}

function Emit-PictureRef {
	param($val, [string]$picTag, [string]$indent)
	if (-not $val) { return }
	$src = $null; $lt = $false; $tpx = $null
	if ($val -is [string]) { $src = $val }
	else { $src = $val.src; if ($val.loadTransparent -eq $true) { $lt = $true }; $tpx = $val.transparentPixel }
	if (-not $src) { return }
	$srcStr = "$src"
	X "$indent<$picTag>"
	if ($srcStr -match '^abs:(.*)$') { X "$indent`t<xr:Abs>$(Esc-XmlText $matches[1])</xr:Abs>" }
	else { X "$indent`t<xr:Ref>$(Esc-XmlText $srcStr)</xr:Ref>" }
	X "$indent`t<xr:LoadTransparent>$(if ($lt) { 'true' } else { 'false' })</xr:LoadTransparent>"
	if ($tpx) { X "$indent`t<xr:TransparentPixel x=`"$($tpx.x)`" y=`"$($tpx.y)`"/>" }
	X "$indent</$picTag>"
}

function Emit-ColumnPics {
	param($el, [string]$indent)
	Emit-PictureRef -val $el.headerPicture -picTag 'HeaderPicture' -indent $indent
	Emit-PictureRef -val $el.footerPicture -picTag 'FooterPicture' -indent $indent
}

function Emit-CommandPicture {
	param($pic, $elemLt, [string]$indent)
	if (-not $pic) { return }
	$src = $null; $lt = $null; $tpx = $null
	if ($pic -is [string]) { $src = $pic }
	else { $src = $pic.src; if ($null -ne $pic.loadTransparent) { $lt = [bool]$pic.loadTransparent }; $tpx = $pic.transparentPixel }
	if (-not $src) { return }
	if ($null -eq $lt -and $null -ne $elemLt) { $lt = [bool]$elemLt }
	$srcStr = "$src"
	X "$indent<Picture>"
	if ($srcStr -match '^abs:(.*)$') { X "$indent`t<xr:Abs>$(Esc-XmlText $matches[1])</xr:Abs>" }
	else { X "$indent`t<xr:Ref>$(Esc-XmlText $srcStr)</xr:Ref>" }
	X "$indent`t<xr:LoadTransparent>$(if ($lt -eq $false) { 'false' } else { 'true' })</xr:LoadTransparent>"
	if ($tpx) { X "$indent`t<xr:TransparentPixel x=`"$($tpx.x)`" y=`"$($tpx.y)`"/>" }
	X "$indent</Picture>"
}

function Emit-GenericScalars {
	param($el, [string]$indent)
	if ($null -eq $el) { return }
	foreach ($s in $script:genericScalars) {
		$p = $el.PSObject.Properties[$s.Key]
		if (-not $p -or $null -eq $p.Value) { continue }
		if ($s.Kind -eq 'bool') {
			X "$indent<$($s.Tag)>$(if ($p.Value){'true'}else{'false'})</$($s.Tag)>"
		} else {
			$v = "$($p.Value)"; if ($v -eq '') { continue }
			X "$indent<$($s.Tag)>$(Esc-XmlText $v)</$($s.Tag)>"
		}
	}
}

function Get-AppearanceValue {
	param($el, [string]$canonical)
	if ($null -eq $el) { return $null }
	$p = $el.PSObject.Properties[$canonical]
	if ($p) { return $p.Value }
	foreach ($syn in $script:appearanceSynonyms.Keys) {
		if ($script:appearanceSynonyms[$syn] -eq $canonical) {
			$pp = $el.PSObject.Properties[$syn]
			if ($pp) { return $pp.Value }
		}
	}
	return $null
}

function Emit-FontTag {
	param([string]$tag, $val, [string]$indent)
	if ($val -is [string]) {
		X "$indent<$tag ref=`"$(Esc-Xml $val)`" kind=`"StyleItem`"/>"
		return
	}
	$attrs = @()
	foreach ($a in @('ref','faceName','height','bold','italic','underline','strikeout','kind','scale')) {
		$pp = $val.PSObject.Properties[$a]
		if ($pp -and $null -ne $pp.Value) {
			$v = $pp.Value
			if ($v -is [bool]) { $v = if ($v) {'true'} else {'false'} }
			$attrs += "$a=`"$(Esc-Xml "$v")`""
		}
	}
	X "$indent<$tag $($attrs -join ' ')/>"
}

function Emit-BorderTag {
	param($val, [string]$indent)
	if ($val -is [string]) { X "$indent<Border ref=`"$(Esc-Xml $val)`"/>"; return }
	$refP = $val.PSObject.Properties['ref']
	if ($refP -and $refP.Value) { X "$indent<Border ref=`"$(Esc-Xml "$($refP.Value)")`"/>"; return }
	$width = if ($val.PSObject.Properties['width'] -and $null -ne $val.width) { $val.width } else { 1 }
	$style = if ($val.PSObject.Properties['style']) { "$($val.style)" } else { $null }
	X "$indent<Border width=`"$width`">"
	if ($style) { X "$indent`t<v8ui:style xsi:type=`"v8ui:ControlBorderType`">$(Esc-XmlText $style)</v8ui:style>" }
	X "$indent</Border>"
}

function Emit-Appearance {
	param($el, [string]$indent, [string]$profile = 'field')
	if ($null -eq $el) { return }
	$order = switch ($profile) {
		'decoration' { $script:appOrderDecoration }
		'button'     { $script:appOrderButton }
		default      { $script:appOrderField }
	}
	foreach ($key in $order) {
		$val = Get-AppearanceValue -el $el -canonical $key
		if ($null -eq $val -or ($val -is [string] -and $val -eq '')) { continue }
		$spec = $script:appearanceSpec[$key]
		switch ($spec.kind) {
			'color'  { X "$indent<$($spec.tag)>$(Esc-XmlText "$val")</$($spec.tag)>" }
			'font'   { Emit-FontTag -tag $spec.tag -val $val -indent $indent }
			'border' { Emit-BorderTag -val $val -indent $indent }
		}
	}
}

function Emit-Layout {
	param($el, [string]$indent, [switch]$skipHeight, [bool]$multiLineDefault = $false)
	# CommandSet (отключённые команды редактора) — общее свойство поля (input/label/check/
	# spreadsheet/html/formatted/picture); в схеме рано (после TitleLocation, перед скалярами).
	if ($el.excludedCommands -and @($el.excludedCommands).Count -gt 0) {
		X "$indent<CommandSet>"
		foreach ($cmd in $el.excludedCommands) { X "$indent`t<ExcludedCommand>$cmd</ExcludedCommand>" }
		X "$indent</CommandSet>"
	}
	Emit-CommonElementProps -el $el -indent $indent
	$amwExplicit = ($el.PSObject.Properties.Name -contains 'autoMaxWidth')
	if ($amwExplicit) {
		if ($el.autoMaxWidth -eq $false) { X "$indent<AutoMaxWidth>false</AutoMaxWidth>" }
	} elseif ($multiLineDefault) {
		X "$indent<AutoMaxWidth>false</AutoMaxWidth>"
	}
	if ($null -ne $el.maxWidth) { X "$indent<MaxWidth>$($el.maxWidth)</MaxWidth>" }
	if ($el.autoMaxHeight -eq $false) { X "$indent<AutoMaxHeight>false</AutoMaxHeight>" }
	if ($null -ne $el.maxHeight) { X "$indent<MaxHeight>$($el.maxHeight)</MaxHeight>" }
	if ($el.width) { X "$indent<Width>$($el.width)</Width>" }
	if (-not $skipHeight -and $el.height) { X "$indent<Height>$($el.height)</Height>" }
	if ($null -ne $el.horizontalStretch) { X "$indent<HorizontalStretch>$(if ($el.horizontalStretch){'true'}else{'false'})</HorizontalStretch>" }
	if ($null -ne $el.verticalStretch) { X "$indent<VerticalStretch>$(if ($el.verticalStretch){'true'}else{'false'})</VerticalStretch>" }
	if ($el.groupHorizontalAlign) { X "$indent<GroupHorizontalAlign>$($el.groupHorizontalAlign)</GroupHorizontalAlign>" }
	if ($el.groupVerticalAlign) { X "$indent<GroupVerticalAlign>$($el.groupVerticalAlign)</GroupVerticalAlign>" }
	if ($el.horizontalAlign) { X "$indent<HorizontalAlign>$($el.horizontalAlign)</HorizontalAlign>" }
	Emit-GenericScalars -el $el -indent $indent
}

function Title-FromName {
	param([string]$name)
	if (-not $name) { return '' }
	$s = [regex]::Replace($name, '([А-ЯA-Z])([А-ЯA-Z][а-яa-z])', '$1 $2')
	$s = [regex]::Replace($s, '([а-яa-z0-9])([А-ЯA-Z])', '$1 $2')
	$parts = $s -split ' '
	if ($parts.Count -eq 0) { return $s }
	$out = New-Object System.Collections.ArrayList
	[void]$out.Add($parts[0])
	for ($i = 1; $i -lt $parts.Count; $i++) {
		$p = $parts[$i]
		if ($p.Length -gt 1 -and $p -ceq $p.ToUpper()) {
			[void]$out.Add($p)
		} else {
			[void]$out.Add($p.ToLower())
		}
	}
	return ($out -join ' ')
}

function Emit-Title {
	# Нет ключа title → авто-вывод из имени (помощь модели).
	# Явный title: "" (или null) → подавить (заголовок не эмитим).
	# Явный непустой → эмитим как есть.
	param($el, [string]$name, [string]$indent, [switch]$auto)
	$hasKey = $null -ne $el.PSObject.Properties['title']
	if ($hasKey) {
		if ($el.title) { Emit-MLText -tag "Title" -text $el.title -indent $indent }
	} elseif ($auto -and $name) {
		Emit-MLText -tag "Title" -text (Title-FromName -name $name) -indent $indent
	}
	# ToolTip элемента (всплывающая подсказка) — по схеме сразу после Title.
	if ($el.tooltip) { Emit-MLText -tag "ToolTip" -text $el.tooltip -indent $indent }
	# ToolTipRepresentation — режим показа подсказки (None/Button/ShowBottom/…), после ToolTip.
	if ($el.tooltipRepresentation) { X "$indent<ToolTipRepresentation>$($el.tooltipRepresentation)</ToolTipRepresentation>" }
}

function Map-TitleLoc {
	param([string]$v)
	switch ("$v".ToLower()) {
		"none"   { "None" }
		"left"   { "Left" }
		"right"  { "Right" }
		"top"    { "Top" }
		"bottom" { "Bottom" }
		"auto"   { "Auto" }
		default  { "$v" }
	}
}

function Emit-TitleLocation {
	param($el, [string]$indent, [string]$smartDefault)
	if ($null -ne $el.PSObject.Properties['titleLocation']) {
		if ($el.titleLocation) { X "$indent<TitleLocation>$(Map-TitleLoc "$($el.titleLocation)")</TitleLocation>" }
	} elseif ($smartDefault) {
		X "$indent<TitleLocation>$smartDefault</TitleLocation>"
	}
}

function Warn-Unrecognized {
	# drop-on-miss enum: значение не распознано → тег не эмитится. Громко, чтобы автор увидел потерю.
	param([string]$key, $raw, [string[]]$valid, [string]$owner)
	Write-Warning "Unrecognized $key '$raw' on '$owner'. Valid values: $($valid -join ', '). Value ignored."
}

function Emit-Group {
	param($el, [string]$name, [int]$id, [string]$indent)

	X "$indent<UsualGroup name=`"$name`" id=`"$id`"$(DI-Attr $el)>"
	$inner = "$indent`t"

	Emit-Title -el $el -name $name -indent $inner

	# Group orientation (направление). Legacy: group:'collapsible' = Vertical + behavior collapsible.
	$groupVal = "$($el.group)".ToLower()
	$orientation = switch ($groupVal) {
		"horizontal"       { "Horizontal" }
		"vertical"         { "Vertical" }
		"alwayshorizontal" { "AlwaysHorizontal" }
		"alwaysvertical"   { "AlwaysVertical" }
		"horizontalifpossible" { "HorizontalIfPossible" }
		"collapsible"      { "Vertical" }
		default            { $null }
	}
	if ($orientation) { X "$inner<Group>$orientation</Group>" }
	elseif ($groupVal) { Warn-Unrecognized 'group orientation' $el.group @('vertical','horizontalIfPossible','alwaysHorizontal') $name }

	# Behavior: ключ behavior (usual/collapsible/popup) → <Behavior>; отсутствие = Авто (не эмитим).
	# Legacy: group:'collapsible' эквивалентно behavior:'collapsible'.
	$behaviorVal = if ($el.behavior) { "$($el.behavior)".ToLower() } elseif ($groupVal -eq "collapsible") { "collapsible" } else { $null }
	$bmap = @{ "usual"="Usual"; "collapsible"="Collapsible"; "popup"="PopUp" }
	if ($behaviorVal -and $bmap.ContainsKey($behaviorVal)) {
		X "$inner<Behavior>$($bmap[$behaviorVal])</Behavior>"
	} elseif ($el.behavior -and -not $bmap.ContainsKey($behaviorVal)) {
		Warn-Unrecognized 'behavior' $el.behavior @('collapsible','popup') $name
	}
	# Collapsed — у Collapsible и PopUp (не привязано к одному behavior)
	if ($el.collapsed -eq $true) { X "$inner<Collapsed>true</Collapsed>" }

	# Representation
	if ($el.representation) {
		$repr = switch ("$($el.representation)") {
			"none"             { "None" }
			"normal"           { "NormalSeparation" }
			"weak"             { "WeakSeparation" }
			"strong"           { "StrongSeparation" }
			default            { "$($el.representation)" }
		}
		X "$inner<Representation>$repr</Representation>"
	}

	# Использование текущей строки группы (после Representation, порядок XSD)
	if ($el.currentRowUse) { X "$inner<CurrentRowUse>$($el.currentRowUse)</CurrentRowUse>" }

	# ShowTitle
	if ($null -ne $el.showTitle) { X "$inner<ShowTitle>$(if ($el.showTitle){'true'}else{'false'})</ShowTitle>" }
	# Заголовок свёрнутого представления (collapsible/popup) — мультиязычный текст
	if ($el.collapsedTitle) { Emit-MLText -tag "CollapsedRepresentationTitle" -text $el.collapsedTitle -indent $inner }

	# United
	if ($el.united -eq $false) { X "$inner<United>false</United>" }

	# Формат значения пути к данным заголовка (<Format>; парный к titleDataPath группы)
	if ($el.format)     { Emit-MLText -tag "Format" -text $el.format -indent $inner }
	if ($el.editFormat) { Emit-MLText -tag "EditFormat" -text $el.editFormat -indent $inner }

	Emit-CommonFlags -el $el -indent $inner
	Emit-Layout -el $el -indent $inner

	# Оформление (цвета/шрифты/граница) — перед компаньоном
	Emit-Appearance -el $el -indent $inner -profile 'field'

	# Companion: ExtendedTooltip
	Emit-Companion -tag "ExtendedTooltip" -name "${name}РасширеннаяПодсказка" -indent $inner -content $el.extendedTooltip

	# Children
	if ($el.children -and $el.children.Count -gt 0) {
		X "$inner<ChildItems>"
		foreach ($child in $el.children) {
			Emit-Element -el $child -indent "$inner`t"
		}
		X "$inner</ChildItems>"
	}

	X "$indent</UsualGroup>"
}

function Emit-ColumnGroup {
	param($el, [string]$name, [int]$id, [string]$indent)

	X "$indent<ColumnGroup name=`"$name`" id=`"$id`"$(DI-Attr $el)>"
	$inner = "$indent`t"

	Emit-Title -el $el -name $name -indent $inner

	# Group orientation (horizontal / vertical / inCell — последнее только здесь)
	$groupVal = "$($el.columnGroup)"
	$orientation = switch ($groupVal) {
		"horizontal" { "Horizontal" }
		"vertical"   { "Vertical" }
		"inCell"     { "InCell" }
		default      { $null }
	}
	if ($orientation) { X "$inner<Group>$orientation</Group>" }
	elseif ($groupVal) { Warn-Unrecognized 'columnGroup orientation' $el.columnGroup @('vertical','horizontal','inCell') $name }

	if ($null -ne $el.showTitle) { X "$inner<ShowTitle>$(if ($el.showTitle){'true'}else{'false'})</ShowTitle>" }
	# showInHeader эмитится общим Emit-CommonElementProps (через Emit-Layout)

	Emit-CommonFlags -el $el -indent $inner
	Emit-Layout -el $el -indent $inner

	# Картинка заголовка колонки-группы (после ShowInHeader/Layout, перед оформлением — порядок XSD)
	Emit-ColumnPics -el $el -indent $inner

	# Оформление (цвета/шрифты/граница) — перед компаньоном
	Emit-Appearance -el $el -indent $inner -profile 'field'

	# Companion: ExtendedTooltip
	Emit-Companion -tag "ExtendedTooltip" -name "${name}РасширеннаяПодсказка" -indent $inner -content $el.extendedTooltip

	# Children
	if ($el.children -and $el.children.Count -gt 0) {
		X "$inner<ChildItems>"
		foreach ($child in $el.children) {
			Emit-Element -el $child -indent "$inner`t"
		}
		X "$inner</ChildItems>"
	}

	X "$indent</ColumnGroup>"
}

function Emit-Input {
	param($el, [string]$name, [int]$id, [string]$indent)

	X "$indent<InputField name=`"$name`" id=`"$id`"$(DI-Attr $el)>"
	$inner = "$indent`t"

	if ($el.path) { X "$inner<DataPath>$($el.path)</DataPath>" }

	Emit-Title -el $el -name $name -indent $inner -auto:(-not $el.path)
	Emit-CommonFlags -el $el -indent $inner

	if ($el.titleLocation) {
		$loc = switch ("$($el.titleLocation)") {
			"none"   { "None" }
			"left"   { "Left" }
			"right"  { "Right" }
			"top"    { "Top" }
			"bottom" { "Bottom" }
			default  { "$($el.titleLocation)" }
		}
		X "$inner<TitleLocation>$loc</TitleLocation>"
	}

	if ($null -ne $el.multiLine) { X "$inner<MultiLine>$(if ($el.multiLine){'true'}else{'false'})</MultiLine>" }
	if ($null -ne $el.passwordMode) { X "$inner<PasswordMode>$(if ($el.passwordMode){'true'}else{'false'})</PasswordMode>" }
	# ChoiceButton — захват «как есть» (платформа эмитит явное значение; ref-поля выводят сама,
	# декомпилятор фиксирует факт. значение). Нет ключа → не эмитим (не додумываем по событию).
	if ($null -ne $el.choiceButton) { X "$inner<ChoiceButton>$(if ($el.choiceButton){'true'}else{'false'})</ChoiceButton>" }
	# Кнопки поля ввода — захват «как есть» (платформа эмитит явное значение, в т.ч. false)
	if ($null -ne $el.clearButton)    { X "$inner<ClearButton>$(if ($el.clearButton){'true'}else{'false'})</ClearButton>" }
	if ($null -ne $el.spinButton)     { X "$inner<SpinButton>$(if ($el.spinButton){'true'}else{'false'})</SpinButton>" }
	if ($null -ne $el.dropListButton) { X "$inner<DropListButton>$(if ($el.dropListButton){'true'}else{'false'})</DropListButton>" }
	if ($null -ne $el.choiceListButton) { X "$inner<ChoiceListButton>$(if ($el.choiceListButton){'true'}else{'false'})</ChoiceListButton>" }
	if ($null -ne $el.markIncomplete) { X "$inner<AutoMarkIncomplete>$(if ($el.markIncomplete){'true'}else{'false'})</AutoMarkIncomplete>" }
	if ($el.editMode) { X "$inner<EditMode>$($el.editMode)</EditMode>" }
	Emit-ColumnPics -el $el -indent $inner
	if ($el.textEdit -eq $false) { X "$inner<TextEdit>false</TextEdit>" }
	# InputField-специфичные скаляры (захват «как есть»: платформа эмитит явное не-дефолтное значение)
	foreach ($p in @(
		@('wrap','Wrap'), @('openButton','OpenButton'), @('listChoiceMode','ListChoiceMode'),
		@('extendedEditMultipleValues','ExtendedEditMultipleValues'), @('chooseType','ChooseType'),
		@('quickChoice','QuickChoice'), @('autoChoiceIncomplete','AutoChoiceIncomplete')
	)) {
		if ($null -ne $el.($p[0])) { X "$inner<$($p[1])>$(if ($el.($p[0])){'true'}else{'false'})</$($p[1])>" }
	}
	# Ограничение доступных типов (поле на составном типе): домен типов + явный набор.
	# availableTypes — формат типа реквизита (§type); Emit-Type сам разбирает мультитип "a | b".
	if ($null -ne $el.typeDomainEnabled) { X "$inner<TypeDomainEnabled>$(if ($el.typeDomainEnabled){'true'}else{'false'})</TypeDomainEnabled>" }
	if ($el.availableTypes) { Emit-Type -typeStr $el.availableTypes -indent $inner -tag 'AvailableTypes' }
	# InputField-специфичные value-скаляры
	foreach ($p in @(
		@('choiceForm','ChoiceForm'), @('choiceHistoryOnInput','ChoiceHistoryOnInput'),
		@('choiceFoldersAndItems','ChoiceFoldersAndItems'), @('footerDataPath','FooterDataPath')
	)) {
		if ($el.($p[0])) { X "$inner<$($p[1])>$(Esc-XmlText "$($el.($p[0]))")</$($p[1])>" }
	}
	# MinValue/MaxValue — типизированное. JSON-число → xs:decimal, строка → xs:string (тип сохранён декомпилятором).
	foreach ($p in @(@('minValue','MinValue'), @('maxValue','MaxValue'))) {
		if ($null -ne $el.($p[0])) {
			$mvt = if ($el.($p[0]) -is [string]) { 'xs:string' } else { 'xs:decimal' }
			X "$inner<$($p[1]) xsi:type=`"$mvt`">$(Esc-XmlText "$($el.($p[0]))")</$($p[1])>"
		}
	}
	if ($el.choiceButtonRepresentation) { X "$inner<ChoiceButtonRepresentation>$($el.choiceButtonRepresentation)</ChoiceButtonRepresentation>" }
	Emit-PictureRef -val $el.choiceButtonPicture -picTag 'ChoiceButtonPicture' -indent $inner
	Emit-Layout -el $el -indent $inner -multiLineDefault ([bool]($el.multiLine -eq $true))

	if ($el.inputHint) {
		Emit-MLText -tag "InputHint" -text $el.inputHint -indent $inner
	}
	if ($null -ne $el.warningOnEdit) { Emit-MLText -tag "WarningOnEdit" -text $el.warningOnEdit -indent $inner }
	if ($null -ne $el.footerText) { Emit-MLText -tag "FooterText" -text $el.footerText -indent $inner }

	# Формат / формат редактирования (LocalStringType — строка или {ru,en})
	if ($el.format)     { Emit-MLText -tag "Format" -text $el.format -indent $inner }
	if ($el.editFormat) { Emit-MLText -tag "EditFormat" -text $el.editFormat -indent $inner }

	Emit-ChoiceList -el $el -indent $inner

	# Связи по типу / связи параметров выбора / параметры выбора
	Emit-TypeLink -el $el -indent $inner
	Emit-ChoiceParameterLinks -el $el -indent $inner
	Emit-ChoiceParameters -el $el -indent $inner

	# Оформление (цвета/шрифты/граница) — перед компаньонами
	Emit-Appearance -el $el -indent $inner -profile 'field'

	# Companions
	Emit-CompanionPanel -tag "ContextMenu" -name "${name}КонтекстноеМеню" -indent $inner -panel $el.contextMenu
	Emit-Companion -tag "ExtendedTooltip" -name "${name}РасширеннаяПодсказка" -indent $inner -content $el.extendedTooltip

	Emit-Events -el $el -elementName $name -indent $inner -typeKey "input"

	X "$indent</InputField>"
}

function Emit-Check {
	param($el, [string]$name, [int]$id, [string]$indent)

	X "$indent<CheckBoxField name=`"$name`" id=`"$id`"$(DI-Attr $el)>"
	$inner = "$indent`t"

	if ($el.path) { X "$inner<DataPath>$($el.path)</DataPath>" }

	Emit-Title -el $el -name $name -indent $inner -auto:(-not $el.path)
	Emit-CommonFlags -el $el -indent $inner

	if ($el.editMode) { X "$inner<EditMode>$($el.editMode)</EditMode>" }
	Emit-ColumnPics -el $el -indent $inner
	# CheckBoxType: нет ключа → умный дефолт Auto; "" → подавить; значение → маппинг
	if ($null -ne $el.PSObject.Properties['checkBoxType']) {
		if ($el.checkBoxType) {
			$cbt = switch ("$($el.checkBoxType)".ToLower()) { 'auto' {'Auto'} 'checkbox' {'CheckBox'} 'switcher' {'Switcher'} 'tumbler' {'Tumbler'} default {"$($el.checkBoxType)"} }
			X "$inner<CheckBoxType>$cbt</CheckBoxType>"
		}
	} else { X "$inner<CheckBoxType>Auto</CheckBoxType>" }

	Emit-TitleLocation -el $el -indent $inner -smartDefault "Right"

	Emit-Layout -el $el -indent $inner

	if ($null -ne $el.warningOnEdit) { Emit-MLText -tag "WarningOnEdit" -text $el.warningOnEdit -indent $inner }
	# FooterDataPath / FooterText — общие cell-свойства колонки (как у input/labelField)
	if ($el.footerDataPath) { X "$inner<FooterDataPath>$(Esc-XmlText "$($el.footerDataPath)")</FooterDataPath>" }
	if ($null -ne $el.footerText) { Emit-MLText -tag "FooterText" -text $el.footerText -indent $inner }

	# Формат / формат редактирования (LocalStringType — строка или {ru,en})
	if ($el.format)     { Emit-MLText -tag "Format" -text $el.format -indent $inner }
	if ($el.editFormat) { Emit-MLText -tag "EditFormat" -text $el.editFormat -indent $inner }

	# Оформление (цвета/шрифты/граница) — перед компаньонами
	Emit-Appearance -el $el -indent $inner -profile 'field'

	# Companions
	Emit-CompanionPanel -tag "ContextMenu" -name "${name}КонтекстноеМеню" -indent $inner -panel $el.contextMenu
	Emit-Companion -tag "ExtendedTooltip" -name "${name}РасширеннаяПодсказка" -indent $inner -content $el.extendedTooltip

	Emit-Events -el $el -elementName $name -indent $inner -typeKey "check"

	X "$indent</CheckBoxField>"
}

function Normalize-ChoiceValue {
	param($value)

	# Booleans
	if ($value -is [bool]) {
		return @{ XsiType = "xs:boolean"; Text = if ($value) { "true" } else { "false" } }
	}
	# Numbers (int / decimal / double)
	if ($value -is [int] -or $value -is [long] -or $value -is [double] -or $value -is [decimal]) {
		return @{ XsiType = "xs:decimal"; Text = "$value" }
	}

	$s = "$value"
	if ([string]::IsNullOrEmpty($s)) {
		return @{ XsiType = "xs:string"; Text = "" }
	}

	# ISO datetime ("2020-01-01T00:00:00") → xs:dateTime
	if ($s -match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}$') {
		return @{ XsiType = "xs:dateTime"; Text = $s }
	}

	# Raw-ссылка по GUID (метаданные.значение, оба GUID): "GUID.GUID" → xr:DesignTimeRef
	# (всегда ссылка, не строка; named-ссылки Enum.X.Y детектятся ниже).
	if ($s -match '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\.[0-9a-fA-F]{8}-[0-9a-fA-F-]+$') {
		return @{ XsiType = "xr:DesignTimeRef"; Text = $s }
	}

	# Try to detect typed reference path: "<Root>.<Type>[.<Member>.<Value>]"
	$parts = $s -split '\.'
	if ($parts.Count -ge 2) {
		$root = $parts[0]
		$canonRoot = $null
		if ($script:refRootSynonyms.ContainsKey($root)) { $canonRoot = $script:refRootSynonyms[$root] }
		elseif ($script:refRootSynonyms.Values -contains $root) { $canonRoot = $root }

		if ($canonRoot) {
			$typeName = $parts[1]
			$normalized = $null

			if ($canonRoot -eq "Enum") {
				if ($parts.Count -eq 2) {
					# "Enum.X" alone — not a value, treat as string
				} elseif ($parts.Count -eq 3) {
					# "Enum.X.Y" — insert .EnumValue. ("EmptyRef" — пустая ссылка, БЕЗ вставки)
					if ($parts[2] -eq 'EmptyRef') { $normalized = "Enum.$typeName.EmptyRef" }
					else { $normalized = "Enum.$typeName.EnumValue.$($parts[2])" }
				} else {
					# "Enum.X.<member>.Y..."  — replace member with EnumValue (handles ЗначениеПеречисления too)
					$member = $parts[2]
					if ($script:enumValueSynonyms -contains $member) {
						$rest = $parts[3..($parts.Count-1)] -join '.'
						$normalized = "Enum.$typeName.EnumValue.$rest"
					} else {
						$rest = $parts[2..($parts.Count-1)] -join '.'
						$normalized = "Enum.$typeName.EnumValue.$rest"
					}
				}
			} else {
				# Other ref roots: just translate root, keep tail as-is
				if ($parts.Count -ge 3) {
					$tail = $parts[1..($parts.Count-1)] -join '.'
					$normalized = "$canonRoot.$tail"
				}
			}

			if ($normalized) {
				return @{ XsiType = "xr:DesignTimeRef"; Text = $normalized }
			}
		}
	}

	return @{ XsiType = "xs:string"; Text = $s }
}

function Emit-ChoicePresentation {
	param($pres, [string]$indent)
	if ($null -eq $pres -or ($pres -is [string] -and [string]::IsNullOrEmpty($pres))) {
		X "$indent<Presentation/>"
		return
	}

	$pairs = @()
	if ($pres -is [string]) {
		$pairs += ,@("ru", $pres)
	} elseif ($pres -is [hashtable] -or $pres -is [System.Collections.IDictionary]) {
		foreach ($k in $pres.Keys) { $pairs += ,@("$k", "$($pres[$k])") }
	} elseif ($pres.PSObject -and $pres.PSObject.Properties) {
		foreach ($p in $pres.PSObject.Properties) { $pairs += ,@("$($p.Name)", "$($p.Value)") }
	} else {
		$pairs += ,@("ru", "$pres")
	}

	X "$indent<Presentation>"
	foreach ($pair in $pairs) {
		X "$indent`t<v8:item>"
		X "$indent`t`t<v8:lang>$($pair[0])</v8:lang>"
		X "$indent`t`t<v8:content>$(Esc-XmlText $pair[1])</v8:content>"
		X "$indent`t</v8:item>"
	}
	X "$indent</Presentation>"
}

function Get-ChoiceValueTag {
	param($norm)
	if ([string]::IsNullOrEmpty($norm.Text)) { return "<Value xsi:type=`"$($norm.XsiType)`"/>" }
	return "<Value xsi:type=`"$($norm.XsiType)`">$(Esc-XmlText $norm.Text)</Value>"
}

function Emit-ChoiceList {
	param($el, [string]$indent)
	if (-not $el.choiceList -or $el.choiceList.Count -eq 0) { return }
	X "$indent<ChoiceList>"
	$itemIndent = "$indent`t"
	foreach ($item in $el.choiceList) {
		# value (+ рус. синоним "значение")
		$valRaw = $null
		if ($item -is [hashtable] -or $item -is [System.Collections.IDictionary]) {
			if ($item.Contains("value")) { $valRaw = $item["value"] }
			elseif ($item.Contains("значение")) { $valRaw = $item["значение"] }
		} else {
			if ($item.PSObject.Properties["value"])    { $valRaw = $item.value }
			elseif ($item.PSObject.Properties["значение"]) { $valRaw = $item."значение" }
		}

		# presentation (presentation OR title синоним)
		$presRaw = $null
		$hasPres = $false
		if ($item -is [hashtable] -or $item -is [System.Collections.IDictionary]) {
			if ($item.Contains("presentation")) { $presRaw = $item["presentation"]; $hasPres = $true }
			elseif ($item.Contains("представление")) { $presRaw = $item["представление"]; $hasPres = $true }
			elseif ($item.Contains("title")) { $presRaw = $item["title"]; $hasPres = $true }
		} else {
			if ($item.PSObject.Properties["presentation"]) { $presRaw = $item.presentation; $hasPres = $true }
			elseif ($item.PSObject.Properties["представление"]) { $presRaw = $item."представление"; $hasPres = $true }
			elseif ($item.PSObject.Properties["title"]) { $presRaw = $item.title; $hasPres = $true }
		}

		# valueType: явный xsi:type значения (системное перечисление ent:*, иной не-примитив) —
		# переопределяет авто-детект (Normalize-ChoiceValue вывела бы xs:string).
		$vtRaw = $null
		if ($item -is [hashtable] -or $item -is [System.Collections.IDictionary]) {
			if ($item.Contains("valueType")) { $vtRaw = "$($item["valueType"])" }
		} elseif ($item.PSObject.Properties["valueType"]) { $vtRaw = "$($item.valueType)" }

		if ($vtRaw -eq 'nil') { $norm = @{ XsiType = $null; Text = $null; Nil = $true } }
		elseif ($vtRaw) { $norm = @{ XsiType = $vtRaw; Text = "$valRaw" } }
		else { $norm = Normalize-ChoiceValue -value $valRaw }

		# авто-вывод presentation, если не задан
		if (-not $hasPres) {
			if ($norm.XsiType -eq "xr:DesignTimeRef") {
				$tail = ($norm.Text -split '\.')[-1]
				$presRaw = Title-FromName -name $tail
			} else {
				$presRaw = $norm.Text
			}
		}

		X "$itemIndent<xr:Item>"
		$valIndent = "$itemIndent`t"
		X "$valIndent<xr:Presentation/>"
		X "$valIndent<xr:CheckState>0</xr:CheckState>"
		X "$valIndent<xr:Value xsi:type=`"FormChoiceListDesTimeValue`">"
		Emit-ChoicePresentation -pres $presRaw -indent "$valIndent`t"
		X "$valIndent`t$(if ($norm.Nil) { '<Value xsi:nil="true"/>' } else { Get-ChoiceValueTag $norm })"
		X "$valIndent</xr:Value>"
		X "$itemIndent</xr:Item>"
	}
	X "$indent</ChoiceList>"
}

function Get-ElProp {
	param($obj, [string[]]$names)
	if ($null -eq $obj) { return $null }
	foreach ($n in $names) {
		if ($obj -is [System.Collections.IDictionary]) {
			if ($obj.Contains($n)) { return $obj[$n] }
		} elseif ($obj.PSObject -and $obj.PSObject.Properties[$n]) {
			return $obj.PSObject.Properties[$n].Value
		}
	}
	return $null
}

function ConvertTo-ScalarLiteral {
	param([string]$s)
	$t = "$s".Trim()
	if ($t -match '^(?i:true)$')  { return $true }
	if ($t -match '^(?i:false)$') { return $false }
	if ($t -match '^-?\d+$')       { return [int]$t }
	if ($t -match '^-?\d+\.\d+$')  { return [double]::Parse($t, [System.Globalization.CultureInfo]::InvariantCulture) }
	return $t
}

function ConvertFrom-ChoiceParamShorthand {
	param([string]$s)
	$eq = $s.IndexOf('=')
	if ($eq -lt 0) { return @{ name = $s.Trim() } }
	$name = $s.Substring(0, $eq).Trim()
	$rest = $s.Substring($eq + 1)
	if ($rest -match ',') {
		$vals = @()
		foreach ($part in ($rest -split ',')) { $vals += ,(ConvertTo-ScalarLiteral $part) }
		return @{ name = $name; value = $vals }
	}
	return @{ name = $name; value = (ConvertTo-ScalarLiteral $rest) }
}

function ConvertFrom-ChoiceParamLinkShorthand {
	param([string]$s)
	$eq = $s.IndexOf('=')
	if ($eq -lt 0) { return @{ name = $s.Trim() } }
	$o = @{ name = $s.Substring(0, $eq).Trim() }
	$rest = $s.Substring($eq + 1).Trim()
	if ($rest -match '^(.*):(?i:(Clear|DontChange|очистить|неизменять))$') {
		$o['dataPath'] = $matches[1].Trim(); $o['valueChange'] = $matches[2]
	} else {
		$o['dataPath'] = $rest
	}
	return $o
}

function ConvertFrom-TypeLinkShorthand {
	param([string]$s)
	if ($s -match '^(.*)#(\d+)$') { return @{ dataPath = $matches[1].Trim(); linkItem = [int]$matches[2] } }
	return @{ dataPath = "$s".Trim() }
}

function Emit-ChoiceParamValue {
	# $isArray передаётся ЯВНО из вызывающего кода: PowerShell разворачивает одноэлементный массив
	# при биндинге параметра ($value становится скаляром), поэтому определять массив тут — ненадёжно
	# (1-элементный список `["X"]` эмитился бы скаляром вместо FixedArray). foreach по скаляру = 1 итерация.
	param($value, [string]$indent, [bool]$isArray)
	X "$indent<Presentation/>"
	if ($isArray) {
		X "$indent<Value xsi:type=`"v8:FixedArray`">"
		foreach ($v in $value) {
			$norm = Normalize-ChoiceValue -value $v
			X "$indent`t<v8:Value xsi:type=`"FormChoiceListDesTimeValue`">"
			X "$indent`t`t<Presentation/>"
			X "$indent`t`t$(Get-ChoiceValueTag $norm)"
			X "$indent`t</v8:Value>"
		}
		X "$indent</Value>"
	} else {
		$norm = Normalize-ChoiceValue -value $value
		X "$indent$(Get-ChoiceValueTag $norm)"
	}
}

function Emit-ChoiceParameters {
	param($el, [string]$indent)
	$cp = $el.choiceParameters
	if (-not $cp -or @($cp).Count -eq 0) { return }
	X "$indent<ChoiceParameters>"
	foreach ($item in @($cp)) {
		if ($item -is [string]) { $item = ConvertFrom-ChoiceParamShorthand $item }
		$name = Get-ElProp $item @('name','имя')
		# Наличие ключа value (≠ значения) + ПРЯМОЙ доступ к значению (без Get-ElProp): его return
		# разворачивает 1-элементный массив (PS unwrap), теряя массив-ность → FixedArray не эмитится.
		# Индексер/member-доступ массив сохраняет; if-выражение/функция-return — нет.
		$hasVal = $false; $val = $null
		if ($item -is [System.Collections.IDictionary]) {
			if ($item.Contains('value')) { $hasVal = $true; $val = $item['value'] }
			elseif ($item.Contains('значение')) { $hasVal = $true; $val = $item['значение'] }
		} else {
			if ($item.PSObject.Properties['value']) { $hasVal = $true; $val = $item.PSObject.Properties['value'].Value }
			elseif ($item.PSObject.Properties['значение']) { $hasVal = $true; $val = $item.PSObject.Properties['значение'].Value }
		}
		$valIsArray = ($val -is [System.Array]) -or ($val -is [System.Collections.IList] -and $val -isnot [string])
		X "$indent`t<app:item name=`"$(Esc-Xml "$name")`">"
		# Параметр выбора без значения → <app:value xsi:nil="true"/> (платформа, 13 в корпусе);
		# со значением (в т.ч. пустой строкой) → FormChoiceListDesTimeValue.
		if (-not $hasVal) {
			X "$indent`t`t<app:value xsi:nil=`"true`"/>"
		} else {
			X "$indent`t`t<app:value xsi:type=`"FormChoiceListDesTimeValue`">"
			Emit-ChoiceParamValue -value $val -indent "$indent`t`t`t" -isArray $valIsArray
			X "$indent`t`t</app:value>"
		}
		X "$indent`t</app:item>"
	}
	X "$indent</ChoiceParameters>"
}

function Emit-ChoiceParameterLinks {
	param($el, [string]$indent)
	$cpl = $el.choiceParameterLinks
	if (-not $cpl -or @($cpl).Count -eq 0) { return }
	X "$indent<ChoiceParameterLinks>"
	foreach ($lk in @($cpl)) {
		if ($lk -is [string]) { $lk = ConvertFrom-ChoiceParamLinkShorthand $lk }
		$name = Get-ElProp $lk @('name','имя')
		$dp = Get-ElProp $lk @('dataPath','path','путь')
		$vcRaw = Get-ElProp $lk @('valueChange','режимИзменения')
		$vc = "Clear"
		if ($vcRaw) {
			$vc = switch -Regex ("$vcRaw".ToLower()) {
				'^(clear|очистить|очистка)$'             { "Clear"; break }
				'^(dontchange|неизменять|неменять|нет)$' { "DontChange"; break }
				default                                  { "$vcRaw" }
			}
		}
		X "$indent`t<xr:Link>"
		X "$indent`t`t<xr:Name>$(Esc-XmlText "$name")</xr:Name>"
		X "$indent`t`t<xr:DataPath xsi:type=`"xs:string`">$(Esc-XmlText "$dp")</xr:DataPath>"
		X "$indent`t`t<xr:ValueChange>$vc</xr:ValueChange>"
		X "$indent`t</xr:Link>"
	}
	X "$indent</ChoiceParameterLinks>"
}

function Emit-TypeLink {
	param($el, [string]$indent)
	$tl = $el.typeLink
	if (-not $tl) { return }
	if ($tl -is [string]) { $tl = ConvertFrom-TypeLinkShorthand $tl }
	$dp = Get-ElProp $tl @('dataPath','path','путь')
	$li = Get-ElProp $tl @('linkItem','элементСвязи')
	if ($null -eq $li) { $li = 0 }
	X "$indent<TypeLink>"
	X "$indent`t<xr:DataPath>$(Esc-XmlText "$dp")</xr:DataPath>"
	X "$indent`t<xr:LinkItem>$li</xr:LinkItem>"
	X "$indent</TypeLink>"
}

function Emit-Radio {
	param($el, [string]$name, [int]$id, [string]$indent)

	X "$indent<RadioButtonField name=`"$name`" id=`"$id`"$(DI-Attr $el)>"
	$inner = "$indent`t"

	if ($el.path) { X "$inner<DataPath>$($el.path)</DataPath>" }

	Emit-Title -el $el -name $name -indent $inner -auto:(-not $el.path)
	Emit-CommonFlags -el $el -indent $inner

	if ($el.editMode) { X "$inner<EditMode>$($el.editMode)</EditMode>" }
	Emit-TitleLocation -el $el -indent $inner -smartDefault "None"

	# RadioButtonType: Auto | RadioButtons | Tumbler. Accept synonyms.
	$rbtRaw = if ($el.radioButtonType) { "$($el.radioButtonType)".Trim() } else { "Auto" }
	$rbt = switch -Regex ($rbtRaw.ToLower()) {
		'^(auto|авто)$'                        { "Auto"; break }
		'^(radiobuttons?|переключатель|радио)$' { "RadioButtons"; break }
		'^(tumbler|тумблер)$'                  { "Tumbler"; break }
		default                                { $rbtRaw }
	}
	X "$inner<RadioButtonType>$rbt</RadioButtonType>"

	if ($null -ne $el.columnsCount) {
		X "$inner<ColumnsCount>$($el.columnsCount)</ColumnsCount>"
	}

	Emit-ChoiceList -el $el -indent $inner

	Emit-Layout -el $el -indent $inner

	if ($null -ne $el.warningOnEdit) { Emit-MLText -tag "WarningOnEdit" -text $el.warningOnEdit -indent $inner }

	# Оформление (цвета/шрифты/граница) — перед компаньонами
	Emit-Appearance -el $el -indent $inner -profile 'field'

	# Companions
	Emit-CompanionPanel -tag "ContextMenu" -name "${name}КонтекстноеМеню" -indent $inner -panel $el.contextMenu
	Emit-Companion -tag "ExtendedTooltip" -name "${name}РасширеннаяПодсказка" -indent $inner -content $el.extendedTooltip

	Emit-Events -el $el -elementName $name -indent $inner -typeKey "radio"

	X "$indent</RadioButtonField>"
}

function Emit-DecorationTitle {
	param($el, [string]$name, [string]$indent, [switch]$auto)
	$hasKey = $null -ne $el.PSObject.Properties['title']
	$titleVal = if ($hasKey) { $el.title } elseif ($auto -and $name) { Title-FromName -name $name } else { $null }
	if ($titleVal) {
		$r = Resolve-MLFormatted $titleVal
		$fmt = if ($null -ne $el.PSObject.Properties['formatted']) { [bool]$el.formatted } else { $r.formatted }
		X "$indent<Title formatted=`"$(if ($fmt) { 'true' } else { 'false' })`">"
		Emit-MLItems -val $r.text -indent "$indent`t"
		X "$indent</Title>"
	}
	if ($el.tooltip) { Emit-MLText -tag "ToolTip" -text $el.tooltip -indent $indent }
	if ($el.tooltipRepresentation) { X "$indent<ToolTipRepresentation>$($el.tooltipRepresentation)</ToolTipRepresentation>" }
}

function Emit-Label {
	param($el, [string]$name, [int]$id, [string]$indent)

	X "$indent<LabelDecoration name=`"$name`" id=`"$id`"$(DI-Attr $el)>"
	$inner = "$indent`t"

	# Порядок как у платформы: own-content (флаги/hyperlink/layout/оформление) ПЕРЕД Title
	# (корпус layout-first 16970 vs 44 — заодно убирает шум атрибуции харнесса на многострочном Title).
	Emit-CommonFlags -el $el -indent $inner
	if ($el.hyperlink -eq $true) { X "$inner<Hyperlink>true</Hyperlink>" }
	Emit-Layout -el $el -indent $inner
	Emit-Appearance -el $el -indent $inner -profile 'decoration'

	Emit-DecorationTitle -el $el -name $name -indent $inner -auto

	# Companions
	Emit-CompanionPanel -tag "ContextMenu" -name "${name}КонтекстноеМеню" -indent $inner -panel $el.contextMenu
	Emit-Companion -tag "ExtendedTooltip" -name "${name}РасширеннаяПодсказка" -indent $inner -content $el.extendedTooltip

	Emit-Events -el $el -elementName $name -indent $inner -typeKey "label"

	X "$indent</LabelDecoration>"
}

function Emit-LabelField {
	param($el, [string]$name, [int]$id, [string]$indent)

	X "$indent<LabelField name=`"$name`" id=`"$id`"$(DI-Attr $el)>"
	$inner = "$indent`t"

	if ($el.path) { X "$inner<DataPath>$($el.path)</DataPath>" }

	Emit-Title -el $el -name $name -indent $inner -auto:(-not $el.path)
	Emit-CommonFlags -el $el -indent $inner

	if ($el.titleLocation) { X "$inner<TitleLocation>$(Map-TitleLoc "$($el.titleLocation)")</TitleLocation>" }
	if ($el.editMode) { X "$inner<EditMode>$($el.editMode)</EditMode>" }
	# FooterDataPath — путь данных подвала колонки (общий cell-prop, как у input); после EditMode
	if ($el.footerDataPath) { X "$inner<FooterDataPath>$(Esc-XmlText "$($el.footerDataPath)")</FooterDataPath>" }
	# PasswordMode на LabelField — платформа эмитит явный false (редко); факт. значение
	if ($null -ne $el.passwordMode) { X "$inner<PasswordMode>$(if ($el.passwordMode){'true'}else{'false'})</PasswordMode>" }
	Emit-ColumnPics -el $el -indent $inner
	# ВНИМАНИЕ: у LabelField платформенный тег именно <Hiperlink> (опечатка 1С), не <Hyperlink>.
	if ($el.hyperlink -eq $true) { X "$inner<Hiperlink>true</Hiperlink>" }
	Emit-Layout -el $el -indent $inner

	if ($null -ne $el.warningOnEdit) { Emit-MLText -tag "WarningOnEdit" -text $el.warningOnEdit -indent $inner }
	if ($null -ne $el.footerText) { Emit-MLText -tag "FooterText" -text $el.footerText -indent $inner }

	# Формат / формат редактирования (LocalStringType — строка или {ru,en})
	if ($el.format)     { Emit-MLText -tag "Format" -text $el.format -indent $inner }
	if ($el.editFormat) { Emit-MLText -tag "EditFormat" -text $el.editFormat -indent $inner }

	# Оформление (цвета/шрифты/граница + header/footer) — перед компаньонами
	Emit-Appearance -el $el -indent $inner -profile 'field'

	# Companions
	Emit-CompanionPanel -tag "ContextMenu" -name "${name}КонтекстноеМеню" -indent $inner -panel $el.contextMenu
	Emit-Companion -tag "ExtendedTooltip" -name "${name}РасширеннаяПодсказка" -indent $inner -content $el.extendedTooltip

	Emit-Events -el $el -elementName $name -indent $inner -typeKey "labelField"

	X "$indent</LabelField>"
}

function Emit-DynListTableBlock {
	param($el, [string]$indent)
	# (useAlternationRowColor — общее свойство таблицы, эмитится в Emit-Table)
	# Group A (гарант. блок, n=5079): дефолт + override
	$ar = if ($el.autoRefresh -eq $true) { "true" } else { "false" }
	X "$indent<AutoRefresh>$ar</AutoRefresh>"
	$arp = if ($el.PSObject.Properties["autoRefreshPeriod"] -and $null -ne $el.autoRefreshPeriod) { $el.autoRefreshPeriod } else { 60 }
	X "$indent<AutoRefreshPeriod>$arp</AutoRefreshPeriod>"
	X "$indent<Period>"
	X "$indent`t<v8:variant xsi:type=`"v8:StandardPeriodVariant`">Custom</v8:variant>"
	X "$indent`t<v8:startDate>0001-01-01T00:00:00</v8:startDate>"
	X "$indent`t<v8:endDate>0001-01-01T00:00:00</v8:endDate>"
	X "$indent</Period>"
	$cfi = if ($el.choiceFoldersAndItems) { $el.choiceFoldersAndItems } else { "Items" }
	X "$indent<ChoiceFoldersAndItems>$cfi</ChoiceFoldersAndItems>"
	$rcr = if ($el.restoreCurrentRow -eq $true) { "true" } else { "false" }
	X "$indent<RestoreCurrentRow>$rcr</RestoreCurrentRow>"
	X "$indent<TopLevelParent xsi:nil=`"true`"/>"
	$sr = if ($el.showRoot -eq $false) { "false" } else { "true" }
	X "$indent<ShowRoot>$sr</ShowRoot>"
	$arc = if ($el.allowRootChoice -eq $true) { "true" } else { "false" }
	X "$indent<AllowRootChoice>$arc</AllowRootChoice>"
	$uodc = if ($el.updateOnDataChange) { $el.updateOnDataChange } else { "Auto" }
	X "$indent<UpdateOnDataChange>$uodc</UpdateOnDataChange>"
	if ($el.userSettingsGroup) { X "$indent<UserSettingsGroup>$($el.userSettingsGroup)</UserSettingsGroup>" }
	$agcru = if ($el.allowGettingCurrentRowURL -eq $false) { "false" } else { "true" }
	X "$indent<AllowGettingCurrentRowURL>$agcru</AllowGettingCurrentRowURL>"
}

function Emit-Table {
	param($el, [string]$name, [int]$id, [string]$indent)

	$script:currentTableName = $name   # дефолт source для кастомных дополнений в commandBar
	X "$indent<Table name=`"$name`" id=`"$id`"$(DI-Attr $el)>"
	$inner = "$indent`t"

	if ($el.path) { X "$inner<DataPath>$($el.path)</DataPath>" }

	Emit-Title -el $el -name $name -indent $inner -auto:(-not $el.path)
	Emit-CommonFlags -el $el -indent $inner

	if ($el.representation) {
		X "$inner<Representation>$($el.representation)</Representation>"
	}
	if ($el.titleLocation) { X "$inner<TitleLocation>$(Map-TitleLoc "$($el.titleLocation)")</TitleLocation>" }
	# ChangeRowSet/Order — эмитим явное значение (в т.ч. false: платформа пишет его на ValueTable)
	if ($el.PSObject.Properties['changeRowSet'] -and $null -ne $el.changeRowSet) {
		X "$inner<ChangeRowSet>$(if ($el.changeRowSet -eq $true){'true'}else{'false'})</ChangeRowSet>"
	}
	if ($el.PSObject.Properties['changeRowOrder'] -and $null -ne $el.changeRowOrder) {
		X "$inner<ChangeRowOrder>$(if ($el.changeRowOrder -eq $true){'true'}else{'false'})</ChangeRowOrder>"
	}
	if ($el.autoInsertNewRow -eq $true) { X "$inner<AutoInsertNewRow>true</AutoInsertNewRow>" }
	# RowFilter — nil-плейсхолдер (всегда пустой); ключ присутствует → эмитим
	if ($el.PSObject.Properties['rowFilter']) { X "$inner<RowFilter xsi:nil=`"true`"/>" }
	# Высота в строках таблицы (<HeightInTableRows>) — отдельное свойство от <Height> (высота элемента,
	# эмитится generic-ом Emit-Layout ниже). Таблица может нести оба (237 в корпусе).
	if ($el.heightInTableRows) { X "$inner<HeightInTableRows>$($el.heightInTableRows)</HeightInTableRows>" }
	if ($el.header -eq $false) { X "$inner<Header>false</Header>" }
	if ($el.footer -eq $true) { X "$inner<Footer>true</Footer>" }

	if ($el.commandBarLocation) {
		X "$inner<CommandBarLocation>$($el.commandBarLocation)</CommandBarLocation>"
	}
	if ($el.searchStringLocation) {
		X "$inner<SearchStringLocation>$($el.searchStringLocation)</SearchStringLocation>"
	}
	if ($el.choiceMode -eq $true) { X "$inner<ChoiceMode>true</ChoiceMode>" }
	# Скаляры таблицы (захват «как есть»). Autofill — СВОЁ свойство таблицы (≠ AutoCommandBar autofill = tableAutofill).
	if ($null -ne $el.autofill) { X "$inner<Autofill>$(if ($el.autofill){'true'}else{'false'})</Autofill>" }
	if ($el.multipleChoice -eq $true) { X "$inner<MultipleChoice>true</MultipleChoice>" }
	if ($el.searchOnInput) { X "$inner<SearchOnInput>$($el.searchOnInput)</SearchOnInput>" }
	if ($null -ne $el.markIncomplete) { X "$inner<AutoMarkIncomplete>$(if ($el.markIncomplete){'true'}else{'false'})</AutoMarkIncomplete>" }
	# Высота шапки/подвала в строках (pass-through; 1С толерантна к порядку детей Table)
	if ($null -ne $el.headerHeight) { X "$inner<HeaderHeight>$($el.headerHeight)</HeaderHeight>" }
	if ($null -ne $el.footerHeight) { X "$inner<FooterHeight>$($el.footerHeight)</FooterHeight>" }
	if ($el.useAlternationRowColor -eq $true) { X "$inner<UseAlternationRowColor>true</UseAlternationRowColor>" }
	if ($el.selectionMode) { X "$inner<SelectionMode>$($el.selectionMode)</SelectionMode>" }
	if ($el.rowSelectionMode) { X "$inner<RowSelectionMode>$($el.rowSelectionMode)</RowSelectionMode>" }
	if ($el.verticalLines -eq $false) { X "$inner<VerticalLines>false</VerticalLines>" }
	if ($el.horizontalLines -eq $false) { X "$inner<HorizontalLines>false</HorizontalLines>" }
	if ($el.initialTreeView) { X "$inner<InitialTreeView>$($el.initialTreeView)</InitialTreeView>" }
	if ($null -ne $el.enableDrag) { X "$inner<EnableDrag>$(if ($el.enableDrag){'true'}else{'false'})</EnableDrag>" }
	if ($el.rowPictureDataPath) { X "$inner<RowPictureDataPath>$($el.rowPictureDataPath)</RowPictureDataPath>" }
	# RowsPicture — та же конвенция, что ValuesPicture (дефолт LoadTransparent=false; abs/TransparentPixel)
	Emit-PictureRef -val $el.rowsPicture -picTag 'RowsPicture' -indent $inner
	# Использование текущей строки таблицы (pass-through; в корпусе соседствует с блоком дин-списка)
	if ($el.currentRowUse) { X "$inner<CurrentRowUse>$($el.currentRowUse)</CurrentRowUse>" }
	# Запрос обновления дин-списка (pass-through; в корпусе всегда PullFromTop)
	if ($el.refreshRequest) { X "$inner<RefreshRequest>$($el.refreshRequest)</RefreshRequest>" }
	# Блок свойств дин-список-таблицы (помечена эвристикой 11b.4)
	if ($el.PSObject.Properties["_dynList"] -and $el._dynList) { Emit-DynListTableBlock -el $el -indent $inner }
	if ($el.viewStatusLocation) { X "$inner<ViewStatusLocation>$($el.viewStatusLocation)</ViewStatusLocation>" }
	if ($el.searchControlLocation) { X "$inner<SearchControlLocation>$($el.searchControlLocation)</SearchControlLocation>" }
	Emit-Layout -el $el -indent $inner

	# CommandSet таблицы эмитится через Emit-Layout (общий механизм поля)

	# Оформление (цвета/граница таблицы) — перед компаньонами
	Emit-Appearance -el $el -indent $inner -profile 'field'

	# Companions
	Emit-CompanionPanel -tag "ContextMenu" -name "${name}КонтекстноеМеню" -indent $inner -panel $el.contextMenu
	# AutoCommandBar: приоритет commandBar-свойства (контент); иначе tableAutofill-shorthand; иначе пусто.
	if ($null -ne $el.commandBar) {
		Emit-CompanionPanel -tag "AutoCommandBar" -name "${name}КоманднаяПанель" -indent $inner -panel $el.commandBar
	} elseif ($null -ne $el.tableAutofill) {
		$acbId = New-Id
		X "$inner<AutoCommandBar name=`"${name}КоманднаяПанель`" id=`"$acbId`">"
		$afVal = if ($el.tableAutofill) { "true" } else { "false" }
		X "$inner`t<Autofill>$afVal</Autofill>"
		X "$inner</AutoCommandBar>"
	} else {
		Emit-Companion -tag "AutoCommandBar" -name "${name}КоманднаяПанель" -indent $inner
	}
	Emit-Companion -tag "ExtendedTooltip" -name "${name}РасширеннаяПодсказка" -indent $inner -content $el.extendedTooltip
	$adds = $el.additions
	Emit-TableAddition -typeKey 'searchString'  -tableName $name -indent $inner -override (Get-AdditionOverride $adds 'searchString')
	Emit-TableAddition -typeKey 'viewStatus'    -tableName $name -indent $inner -override (Get-AdditionOverride $adds 'viewStatus')
	Emit-TableAddition -typeKey 'searchControl' -tableName $name -indent $inner -override (Get-AdditionOverride $adds 'searchControl')

	# Columns
	if ($el.columns -and $el.columns.Count -gt 0) {
		X "$inner<ChildItems>"
		foreach ($col in $el.columns) {
			Emit-Element -el $col -indent "$inner`t"
		}
		X "$inner</ChildItems>"
	}

	Emit-Events -el $el -elementName $name -indent $inner -typeKey "table"

	X "$indent</Table>"
}

function Emit-Pages {
	param($el, [string]$name, [int]$id, [string]$indent)

	X "$indent<Pages name=`"$name`" id=`"$id`"$(DI-Attr $el)>"
	$inner = "$indent`t"

	Emit-Title -el $el -name $name -indent $inner

	if ($el.pagesRepresentation) {
		X "$inner<PagesRepresentation>$($el.pagesRepresentation)</PagesRepresentation>"
	}
	# Использование текущей строки (после PagesRepresentation, порядок XSD)
	if ($el.currentRowUse) { X "$inner<CurrentRowUse>$($el.currentRowUse)</CurrentRowUse>" }

	Emit-CommonFlags -el $el -indent $inner
	Emit-Layout -el $el -indent $inner

	# Оформление (цвета/шрифты/граница) заголовка группы страниц — TitleFont/TitleTextColor/… (как у Page)
	Emit-Appearance -el $el -indent $inner -profile 'field'

	# Companion
	Emit-Companion -tag "ExtendedTooltip" -name "${name}РасширеннаяПодсказка" -indent $inner -content $el.extendedTooltip

	Emit-Events -el $el -elementName $name -indent $inner -typeKey "pages"

	# Children (pages)
	if ($el.children -and $el.children.Count -gt 0) {
		X "$inner<ChildItems>"
		foreach ($child in $el.children) {
			Emit-Element -el $child -indent "$inner`t"
		}
		X "$inner</ChildItems>"
	}

	X "$indent</Pages>"
}

function Emit-Page {
	param($el, [string]$name, [int]$id, [string]$indent)

	X "$indent<Page name=`"$name`" id=`"$id`"$(DI-Attr $el)>"
	$inner = "$indent`t"

	Emit-Title -el $el -name $name -indent $inner -auto
	Emit-CommonFlags -el $el -indent $inner

	# Картинка страницы (иконка вкладки): после Title/флагов, перед Group (порядок XSD).
	# Конвенция как у ValuesPicture (дефолт LoadTransparent=false): скаляр-Ref/'abs:X' или объект.
	Emit-PictureRef -val $el.picture -picTag 'Picture' -indent $inner

	if ($el.group) {
		# Доступные значения страницы/обычной группы: Vertical / HorizontalIfPossible / AlwaysHorizontal
		# (InCell — только у columnGroup). Horizontal/AlwaysVertical оставлены forgiving (legacy).
		$orientation = switch ("$($el.group)") {
			"horizontal"          { "Horizontal" }
			"vertical"            { "Vertical" }
			"alwaysHorizontal"    { "AlwaysHorizontal" }
			"alwaysVertical"      { "AlwaysVertical" }
			"horizontalIfPossible" { "HorizontalIfPossible" }
			default               { $null }
		}
		if ($orientation) { X "$inner<Group>$orientation</Group>" }
		else { Warn-Unrecognized 'page group orientation' $el.group @('vertical','horizontalIfPossible','alwaysHorizontal') $name }
	}
	if ($null -ne $el.showTitle) { X "$inner<ShowTitle>$(if ($el.showTitle){'true'}else{'false'})</ShowTitle>" }
	# Формат значения пути к данным заголовка (<Format>; парный к titleDataPath страницы)
	if ($el.format)     { Emit-MLText -tag "Format" -text $el.format -indent $inner }
	if ($el.editFormat) { Emit-MLText -tag "EditFormat" -text $el.editFormat -indent $inner }
	Emit-Layout -el $el -indent $inner

	# Оформление страницы (BackColor / TitleTextColor / TitleFont) — после ShowTitle, перед компаньоном
	Emit-Appearance -el $el -indent $inner -profile 'field'

	# Companion
	Emit-Companion -tag "ExtendedTooltip" -name "${name}РасширеннаяПодсказка" -indent $inner -content $el.extendedTooltip

	# Children
	if ($el.children -and $el.children.Count -gt 0) {
		X "$inner<ChildItems>"
		foreach ($child in $el.children) {
			Emit-Element -el $child -indent "$inner`t"
		}
		X "$inner</ChildItems>"
	}

	X "$indent</Page>"
}

function Emit-Button {
	param($el, [string]$name, [int]$id, [string]$indent, [bool]$inCmdBar = $false)

	X "$indent<Button name=`"$name`" id=`"$id`"$(DI-Attr $el)>"
	$inner = "$indent`t"
	# (общие свойства — через Emit-Layout ниже; отдельный вызов был бы двойной эмиссией)

	# Type — context-aware:
	# Inside command bar (cmdBar/autoCmdBar/popup) only CommandBarButton/CommandBarHyperlink are valid.
	# UsualButton/Hyperlink would be silently ignored by 1C.
	$btnType = $null
	if ($el.type) {
		$rawType = "$($el.type)"
		if ($inCmdBar) {
			# Be forgiving: any "ordinary button" hint resolves to CommandBarButton,
			# any "hyperlink" hint resolves to CommandBarHyperlink. The model can pass
			# either DSL ("usual"/"hyperlink") or XML names — all map to the right kind.
			switch ($rawType) {
				"usual"                { $btnType = "CommandBarButton" }
				"UsualButton"          { $btnType = "CommandBarButton" }
				"commandBar"           { $btnType = "CommandBarButton" }
				"CommandBarButton"     { $btnType = "CommandBarButton" }
				"hyperlink"            { $btnType = "CommandBarHyperlink" }
				"Hyperlink"            { $btnType = "CommandBarHyperlink" }
				"CommandBarHyperlink"  { $btnType = "CommandBarHyperlink" }
				default                { $btnType = $rawType }
			}
		} else {
			# Symmetric: any "ordinary button" hint → UsualButton, any "hyperlink" → Hyperlink.
			switch ($rawType) {
				"usual"                { $btnType = "UsualButton" }
				"UsualButton"          { $btnType = "UsualButton" }
				"commandBar"           { $btnType = "UsualButton" }
				"CommandBarButton"     { $btnType = "UsualButton" }
				"hyperlink"            { $btnType = "Hyperlink" }
				"Hyperlink"            { $btnType = "Hyperlink" }
				"CommandBarHyperlink"  { $btnType = "Hyperlink" }
				default                { $btnType = $rawType }
			}
		}
	} elseif ($inCmdBar) {
		$btnType = "CommandBarButton"
	}
	if ($btnType) {
		X "$inner<Type>$btnType</Type>"
	}

	# CommandName
	if ($el.command) {
		X "$inner<CommandName>Form.Command.$($el.command)</CommandName>"
	}
	# commandName — глобальная команда «как есть» (CommonCommand.X, Catalog.X.Command.Y …), без обёртки Form.
	if ($el.commandName -and -not $el.command) {
		X "$inner<CommandName>$($el.commandName)</CommandName>"
	}
	if ($el.stdCommand) {
		$sc = "$($el.stdCommand)"
		if ($sc -match '^(.+)\.(.+)$') {
			X "$inner<CommandName>Form.Item.$($Matches[1]).StandardCommand.$($Matches[2])</CommandName>"
		} else {
			X "$inner<CommandName>Form.StandardCommand.$sc</CommandName>"
		}
	}
	# Parameter команды (после CommandName): строка → xr:MDObjectRef (объект метаданных);
	# объект {type} → v8:TypeDescription (грамматика типа). Forgiving-синоним 'параметр'.
	$btnParam = if ($null -ne $el.PSObject.Properties['parameter']) { $el.parameter } elseif ($null -ne $el.PSObject.Properties['параметр']) { $el.параметр } else { $null }
	if ($null -ne $btnParam) {
		if (($btnParam -is [System.Management.Automation.PSCustomObject] -or $btnParam -is [hashtable]) -and $btnParam.type) {
			Emit-Type -typeStr "$($btnParam.type)" -indent $inner -tag "Parameter" -tagAttrs ' xsi:type="v8:TypeDescription"'
		} else {
			X "$inner<Parameter xsi:type=`"xr:MDObjectRef`">$(Esc-XmlText "$btnParam")</Parameter>"
		}
	}
	# DataPath — привязка команды кнопки к контексту (Объект.Ref, Items.X.CurrentData.Поле)
	if ($el.path) { X "$inner<DataPath>$($el.path)</DataPath>" }

	$btnAuto = -not ($el.command -or $el.commandName -or $el.stdCommand)
	Emit-Title -el $el -name $name -indent $inner -auto:$btnAuto
	Emit-CommonFlags -el $el -indent $inner

	if ($el.defaultButton -eq $true) { X "$inner<DefaultButton>true</DefaultButton>" }
	# Check (пометка toggle-кнопки командной панели) — платформа эмитит только true.
	# Ключ 'checked' (не 'check': 'check' — тип-ключ CheckBoxField, был бы конфликт диспетчера типов)
	if ($el.checked -eq $true) { X "$inner<Check>true</Check>" }

	# Picture
	Emit-CommandPicture -pic $el.picture -elemLt $el.loadTransparent -indent $inner

	if ($el.representation) {
		X "$inner<Representation>$($el.representation)</Representation>"
	}

	if ($el.locationInCommandBar) {
		X "$inner<LocationInCommandBar>$($el.locationInCommandBar)</LocationInCommandBar>"
	}
	Emit-Layout -el $el -indent $inner

	# Оформление (цвета/шрифт/граница) — перед компаньоном (профиль кнопки)
	Emit-Appearance -el $el -indent $inner -profile 'button'

	# Companion
	Emit-Companion -tag "ExtendedTooltip" -name "${name}РасширеннаяПодсказка" -indent $inner -content $el.extendedTooltip

	Emit-Events -el $el -elementName $name -indent $inner -typeKey "button"

	X "$indent</Button>"
}

function Emit-PictureDecoration {
	param($el, [string]$name, [int]$id, [string]$indent)

	X "$indent<PictureDecoration name=`"$name`" id=`"$id`"$(DI-Attr $el)>"
	$inner = "$indent`t"

	Emit-DecorationTitle -el $el -name $name -indent $inner
	# Текст при невыбранной картинке (NonselectedPictureText) — после Title (порядок корпуса)
	if ($null -ne $el.nonselectedPictureText) { Emit-MLText -tag "NonselectedPictureText" -text $el.nonselectedPictureText -indent $inner }
	Emit-CommonFlags -el $el -indent $inner

	# Источник картинки — ТОЛЬКО $el.src (у PictureDecoration ключ 'picture' = тип/имя элемента, не источник).
	# Префикс "abs:" → встроенная картинка <xr:Abs>; иначе именованная/стилевая <xr:Ref>.
	if ($el.src) {
		$srcStr = "$($el.src)"
		$lt = if ($el.loadTransparent -eq $true) { "true" } else { "false" }
		X "$inner<Picture>"
		if ($srcStr -match '^abs:(.*)$') { X "$inner`t<xr:Abs>$(Esc-XmlText $matches[1])</xr:Abs>" }
		else { X "$inner`t<xr:Ref>$(Esc-XmlText $srcStr)</xr:Ref>" }
		X "$inner`t<xr:LoadTransparent>$lt</xr:LoadTransparent>"
		if ($el.transparentPixel) { X "$inner`t<xr:TransparentPixel x=`"$($el.transparentPixel.x)`" y=`"$($el.transparentPixel.y)`"/>" }
		X "$inner</Picture>"
	}

	if ($el.hyperlink -eq $true) { X "$inner<Hyperlink>true</Hyperlink>" }
	Emit-Layout -el $el -indent $inner
	# EnableDrag — фактическое значение (декорация-картинка перетаскиваема; декомпилятор ловит generic-ом)
	if ($null -ne $el.enableDrag) { X "$inner<EnableDrag>$(if ($el.enableDrag){'true'}else{'false'})</EnableDrag>" }

	# Оформление (цвета/шрифт/граница) — профиль декорации (1С толерантна к порядку appearance)
	Emit-Appearance -el $el -indent $inner -profile 'decoration'

	# Companions
	Emit-CompanionPanel -tag "ContextMenu" -name "${name}КонтекстноеМеню" -indent $inner -panel $el.contextMenu
	Emit-Companion -tag "ExtendedTooltip" -name "${name}РасширеннаяПодсказка" -indent $inner -content $el.extendedTooltip

	Emit-Events -el $el -elementName $name -indent $inner -typeKey "picture"

	X "$indent</PictureDecoration>"
}

function Emit-PictureField {
	param($el, [string]$name, [int]$id, [string]$indent)

	X "$indent<PictureField name=`"$name`" id=`"$id`"$(DI-Attr $el)>"
	$inner = "$indent`t"

	if ($el.path) { X "$inner<DataPath>$($el.path)</DataPath>" }

	Emit-Title -el $el -name $name -indent $inner
	Emit-CommonFlags -el $el -indent $inner

	if ($el.editMode) { X "$inner<EditMode>$($el.editMode)</EditMode>" }
	Emit-ColumnPics -el $el -indent $inner
	if ($el.titleLocation) { X "$inner<TitleLocation>$(Map-TitleLoc "$($el.titleLocation)")</TitleLocation>" }
	if ($el.hyperlink -eq $true) { X "$inner<Hyperlink>true</Hyperlink>" }

	Emit-Layout -el $el -indent $inner
	# EnableDrag — фактическое значение (поле картинки перетаскиваемо; декомпилятор ловит generic-ом)
	if ($null -ne $el.enableDrag) { X "$inner<EnableDrag>$(if ($el.enableDrag){'true'}else{'false'})</EnableDrag>" }

	# FooterDataPath / FooterText — общие cell-свойства колонки (как у input/labelField)
	if ($el.footerDataPath) { X "$inner<FooterDataPath>$(Esc-XmlText "$($el.footerDataPath)")</FooterDataPath>" }
	if ($null -ne $el.footerText) { Emit-MLText -tag "FooterText" -text $el.footerText -indent $inner }

	# ValuesPicture — picture (collection) used to render the field's value.
	# Required for a Boolean-bound PictureField to actually show an icon.
	# Скаляр (Ref) или объект {src, loadTransparent}; LoadTransparent эмитится всегда.
	Emit-PictureRef -val $el.valuesPicture -picTag 'ValuesPicture' -indent $inner
	if ($null -ne $el.nonselectedPictureText) { Emit-MLText -tag "NonselectedPictureText" -text $el.nonselectedPictureText -indent $inner }

	# Оформление (цвета/шрифты/граница) — перед компаньонами
	Emit-Appearance -el $el -indent $inner -profile 'field'

	# Companions
	Emit-CompanionPanel -tag "ContextMenu" -name "${name}КонтекстноеМеню" -indent $inner -panel $el.contextMenu
	Emit-Companion -tag "ExtendedTooltip" -name "${name}РасширеннаяПодсказка" -indent $inner -content $el.extendedTooltip

	Emit-Events -el $el -elementName $name -indent $inner -typeKey "picField"

	X "$indent</PictureField>"
}

function Emit-Calendar {
	param($el, [string]$name, [int]$id, [string]$indent)

	X "$indent<CalendarField name=`"$name`" id=`"$id`"$(DI-Attr $el)>"
	$inner = "$indent`t"

	if ($el.path) { X "$inner<DataPath>$($el.path)</DataPath>" }

	Emit-Title -el $el -name $name -indent $inner -auto:(-not $el.path)
	Emit-CommonFlags -el $el -indent $inner

	if ($el.titleLocation) {
		$loc = switch ("$($el.titleLocation)") {
			"none"   { "None" }
			"left"   { "Left" }
			"right"  { "Right" }
			"top"    { "Top" }
			"bottom" { "Bottom" }
			"auto"   { "Auto" }
			default  { "$($el.titleLocation)" }
		}
		X "$inner<TitleLocation>$loc</TitleLocation>"
	}

	Emit-Layout -el $el -indent $inner

	# Календарно-специфичные свойства (порядок схемы: после layout, до companions)
	if ($el.selectionMode) { X "$inner<SelectionMode>$($el.selectionMode)</SelectionMode>" }
	if ($null -ne $el.showCurrentDate) { $v = if ($el.showCurrentDate) { "true" } else { "false" }; X "$inner<ShowCurrentDate>$v</ShowCurrentDate>" }
	if ($null -ne $el.widthInMonths) { X "$inner<WidthInMonths>$($el.widthInMonths)</WidthInMonths>" }
	if ($null -ne $el.heightInMonths) { X "$inner<HeightInMonths>$($el.heightInMonths)</HeightInMonths>" }
	if ($null -ne $el.showMonthsPanel) { $v = if ($el.showMonthsPanel) { "true" } else { "false" }; X "$inner<ShowMonthsPanel>$v</ShowMonthsPanel>" }

	# Оформление (цвета/шрифты/граница) — перед компаньонами
	Emit-Appearance -el $el -indent $inner -profile 'field'

	# Companions
	Emit-CompanionPanel -tag "ContextMenu" -name "${name}КонтекстноеМеню" -indent $inner -panel $el.contextMenu
	Emit-Companion -tag "ExtendedTooltip" -name "${name}РасширеннаяПодсказка" -indent $inner -content $el.extendedTooltip

	Emit-Events -el $el -elementName $name -indent $inner -typeKey "calendar"

	X "$indent</CalendarField>"
}

function Emit-SimpleField {
	param($el, [string]$name, [int]$id, [string]$indent, [string]$xmlTag, [string]$typeKey)

	X "$indent<$xmlTag name=`"$name`" id=`"$id`"$(DI-Attr $el)>"
	$inner = "$indent`t"

	if ($el.path) { X "$inner<DataPath>$($el.path)</DataPath>" }
	Emit-Title -el $el -name $name -indent $inner -auto:(-not $el.path)
	Emit-CommonFlags -el $el -indent $inner
	if ($el.titleLocation) { X "$inner<TitleLocation>$(Map-TitleLoc "$($el.titleLocation)")</TitleLocation>" }
	if ($el.editMode) { X "$inner<EditMode>$($el.editMode)</EditMode>" }

	Emit-Layout -el $el -indent $inner

	# EnableDrag — фактическое значение (SpreadSheet; платформа эмитит явный false). enableStartDrag — через Emit-Layout.
	if ($null -ne $el.enableDrag) { X "$inner<EnableDrag>$(if ($el.enableDrag){'true'}else{'false'})</EnableDrag>" }

	# Датчики (ProgressBar/TrackBar) — числовые скаляры (без xsi:type)
	foreach ($p in @(@('minValue','MinValue'), @('maxValue','MaxValue'), @('largeStep','LargeStep'), @('markingStep','MarkingStep'), @('step','Step'))) {
		if ($null -ne $el.($p[0])) { X "$inner<$($p[1])>$($el.($p[0]))</$($p[1])>" }
	}

	# Оформление (цвета/шрифты/граница) — перед компаньонами
	Emit-Appearance -el $el -indent $inner -profile 'field'

	# Companions
	Emit-CompanionPanel -tag "ContextMenu" -name "${name}КонтекстноеМеню" -indent $inner -panel $el.contextMenu
	Emit-Companion -tag "ExtendedTooltip" -name "${name}РасширеннаяПодсказка" -indent $inner -content $el.extendedTooltip

	Emit-Events -el $el -elementName $name -indent $inner -typeKey $typeKey

	X "$indent</$xmlTag>"
}

function Emit-GanttChart {
	param($el, [string]$name, [int]$id, [string]$indent)
	X "$indent<GanttChartField name=`"$name`" id=`"$id`"$(DI-Attr $el)>"
	$inner = "$indent`t"
	if ($el.path) { X "$inner<DataPath>$($el.path)</DataPath>" }
	Emit-Title -el $el -name $name -indent $inner -auto:(-not $el.path)
	Emit-CommonFlags -el $el -indent $inner
	if ($el.titleLocation) { X "$inner<TitleLocation>$(Map-TitleLoc "$($el.titleLocation)")</TitleLocation>" }
	Emit-Layout -el $el -indent $inner
	Emit-Appearance -el $el -indent $inner -profile 'field'
	Emit-CompanionPanel -tag "ContextMenu" -name "${name}КонтекстноеМеню" -indent $inner -panel $el.contextMenu
	Emit-Companion -tag "ExtendedTooltip" -name "${name}РасширеннаяПодсказка" -indent $inner -content $el.extendedTooltip
	# Вложенная таблица диаграммы Ганта (стандартный Table — переиспользуем Emit-Element)
	if ($el.ganttTable) { Emit-Element -el $el.ganttTable -indent $inner }
	Emit-Events -el $el -elementName $name -indent $inner -typeKey "ganttChart"
	X "$indent</GanttChartField>"
}

function Emit-CommandBar {
	param($el, [string]$name, [int]$id, [string]$indent)

	X "$indent<CommandBar name=`"$name`" id=`"$id`"$(DI-Attr $el)>"
	$inner = "$indent`t"

	Emit-Title -el $el -name $name -indent $inner

	if ($el.commandSource) { X "$inner<CommandSource>$($el.commandSource)</CommandSource>" }

	if ($el.autofill -eq $true) { X "$inner<Autofill>true</Autofill>" }

	# CommandBar хранит HorizontalLocation фактически (включая Auto — декомпилятор ловит только при наличии);
	# ≠ дополнениям, где Auto = умолчание-скип (Get-HLocation).
	if ($el.horizontalLocation) {
		$hlv = switch ("$($el.horizontalLocation)".ToLower()) { 'auto' {'Auto'} 'left' {'Left'} 'right' {'Right'} 'center' {'Center'} default {"$($el.horizontalLocation)"} }
		X "$inner<HorizontalLocation>$hlv</HorizontalLocation>"
	}
	Emit-CommonFlags -el $el -indent $inner
	Emit-Layout -el $el -indent $inner
	Emit-Companion -tag "ExtendedTooltip" -name "${name}РасширеннаяПодсказка" -indent $inner -content $el.extendedTooltip

	# Children
	if ($el.children -and $el.children.Count -gt 0) {
		X "$inner<ChildItems>"
		foreach ($child in $el.children) {
			Emit-Element -el $child -indent "$inner`t" -inCmdBar $true
		}
		X "$inner</ChildItems>"
	}

	X "$indent</CommandBar>"
}

function Emit-ButtonGroup {
	param($el, [string]$name, [int]$id, [string]$indent)

	X "$indent<ButtonGroup name=`"$name`" id=`"$id`"$(DI-Attr $el)>"
	$inner = "$indent`t"

	Emit-Title -el $el -name $name -indent $inner

	if ($el.commandSource) { X "$inner<CommandSource>$($el.commandSource)</CommandSource>" }

	if ($el.representation) {
		X "$inner<Representation>$($el.representation)</Representation>"
	}

	Emit-CommonFlags -el $el -indent $inner
	Emit-Layout -el $el -indent $inner

	# Companion: ExtendedTooltip
	Emit-Companion -tag "ExtendedTooltip" -name "${name}РасширеннаяПодсказка" -indent $inner -content $el.extendedTooltip

	# Children (кнопки в контексте командной панели)
	if ($el.children -and $el.children.Count -gt 0) {
		X "$inner<ChildItems>"
		foreach ($child in $el.children) {
			Emit-Element -el $child -indent "$inner`t" -inCmdBar $true
		}
		X "$inner</ChildItems>"
	}

	X "$indent</ButtonGroup>"
}

function Emit-Popup {
	param($el, [string]$name, [int]$id, [string]$indent)

	X "$indent<Popup name=`"$name`" id=`"$id`"$(DI-Attr $el)>"
	$inner = "$indent`t"

	Emit-Title -el $el -name $name -indent $inner -auto
	Emit-CommonFlags -el $el -indent $inner

	# Источник команд попапа (после Title/ToolTip, перед компаньоном) — как у ButtonGroup/CommandBar
	if ($el.commandSource) { X "$inner<CommandSource>$($el.commandSource)</CommandSource>" }

	Emit-CommandPicture -pic $el.picture -elemLt $el.loadTransparent -indent $inner

	if ($el.representation) {
		X "$inner<Representation>$($el.representation)</Representation>"
	}
	Emit-Layout -el $el -indent $inner

	# Оформление попапа (TitleTextColor / TitleFont) — перед компаньоном
	Emit-Appearance -el $el -indent $inner -profile 'field'

	Emit-Companion -tag "ExtendedTooltip" -name "${name}РасширеннаяПодсказка" -indent $inner -content $el.extendedTooltip

	# Children
	if ($el.children -and $el.children.Count -gt 0) {
		X "$inner<ChildItems>"
		foreach ($child in $el.children) {
			Emit-Element -el $child -indent "$inner`t" -inCmdBar $true
		}
		X "$inner</ChildItems>"
	}

	X "$indent</Popup>"
}

function Normalize-PanelSynonyms {
	param($el)
	if ($null -eq $el) { return }
	$panelSyns = @{
		'commandBar' = @('commandBar','autoCommandBar','AutoCommandBar','autoCmdBar','cmdBar','КоманднаяПанель')
		'contextMenu' = @('contextMenu','ContextMenu','КонтекстноеМеню')
	}
	foreach ($canon in $panelSyns.Keys) {
		foreach ($syn in $panelSyns[$canon]) {
			$p = $el.PSObject.Properties[$syn]
			if ($null -ne $p -and ($p.Value -is [array] -or $p.Value -is [System.Management.Automation.PSCustomObject])) {
				if ($syn -ne $canon -and $null -eq $el.PSObject.Properties[$canon]) {
					$v = $p.Value
					$el.PSObject.Properties.Remove($syn) | Out-Null
					$el | Add-Member -NotePropertyName $canon -NotePropertyValue $v -Force
				}
				break
			}
		}
	}
}

function Normalize-ElementSynonyms {
	param($el)
	if ($null -eq $el) { return }
	Normalize-PanelSynonyms $el
	# Тип-синонимы (commandBar/autoCommandBar → элемент-тип) применяем ТОЛЬКО к строковому
	# значению (имя элемента); объект/массив уже отнесён к панель-свойству выше.
	$typeSyn = @{ "commandBar" = "cmdBar"; "autoCommandBar" = "autoCmdBar" }
	foreach ($pair in $typeSyn.GetEnumerator()) {
		$src = $el.PSObject.Properties[$pair.Key]
		if ($null -ne $src -and ($src.Value -is [string]) -and $null -eq $el.PSObject.Properties[$pair.Value]) {
			$val = $el.($pair.Key)
			$el.PSObject.Properties.Remove($pair.Key) | Out-Null
			$el | Add-Member -NotePropertyName $pair.Value -NotePropertyValue $val -Force
		}
	}
	if ($el.PSObject.Properties["extTooltip"] -and $null -eq $el.PSObject.Properties["extendedTooltip"]) {
		$val = $el.extTooltip
		$el.PSObject.Properties.Remove("extTooltip") | Out-Null
		$el | Add-Member -NotePropertyName "extendedTooltip" -NotePropertyValue $val -Force
	}
	# Рекурсия в детей панелей (commandBar/contextMenu) — нормализуем кнопки/группы внутри
	foreach ($pk in @('commandBar','contextMenu')) {
		$pp = $el.PSObject.Properties[$pk]
		if ($null -ne $pp) {
			$kids = if ($pp.Value -is [array]) { $pp.Value } elseif ($null -ne $pp.Value) { $pp.Value.children } else { $null }
			if ($kids) { foreach ($child in $kids) { Normalize-ElementSynonyms $child } }
		}
	}
	if ($el.PSObject.Properties["children"] -and $el.children) {
		foreach ($child in $el.children) { Normalize-ElementSynonyms $child }
	}
	if ($el.PSObject.Properties["columns"] -and $el.columns) {
		foreach ($child in $el.columns) { Normalize-ElementSynonyms $child }
	}
}

function ApplyDynamicListTableHeuristic {
	param($el, [string]$listName, [bool]$hasMainTable)
	if ($null -eq $el) { return }
	if ($el.PSObject.Properties["table"] -and $null -ne $el.table -and "$($el.path)" -eq $listName) {
		# Маркер дин-список-таблицы → Emit-Table эмитит блок свойств (Group A defaults)
		$el | Add-Member -NotePropertyName "_dynList" -NotePropertyValue $true -Force
		if ($null -eq $el.PSObject.Properties["tableAutofill"]) {
			$el | Add-Member -NotePropertyName "tableAutofill" -NotePropertyValue $false -Force
		}
		if ($null -eq $el.PSObject.Properties["commandBarLocation"]) {
			$el | Add-Member -NotePropertyName "commandBarLocation" -NotePropertyValue "None" -Force
		}
		# RowPictureDataPath: умный дефолт <Список>.DefaultPicture, если ключ ОТСУТСТВУЕТ.
		# Декомпилятор опускает ключ при rpdp == smart-default (ждёт реинъекции); реальное отсутствие
		# фиксирует ""-маркером (НЕ перезатирается). Гейт hasMainTable снят: дин-список без mainTable
		# (напр. query-based) тоже несёт RowPictureDataPath.
		if ($null -eq $el.PSObject.Properties["rowPictureDataPath"]) {
			$el | Add-Member -NotePropertyName "rowPictureDataPath" -NotePropertyValue "$listName.DefaultPicture" -Force
		}
	}
	if ($el.PSObject.Properties["children"] -and $el.children) {
		foreach ($child in $el.children) { ApplyDynamicListTableHeuristic $child $listName $hasMainTable }
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

# Все пространства имён корня формы — эмиттер пишет xsi:type, ent:, style: и др.
$allNsDecl = 'xmlns="http://v8.1c.ru/8.3/xcf/logform" xmlns:app="http://v8.1c.ru/8.2/managed-application/core" xmlns:cfg="http://v8.1c.ru/8.1/data/enterprise/current-config" xmlns:dcscor="http://v8.1c.ru/8.1/data-composition-system/core" xmlns:dcssch="http://v8.1c.ru/8.1/data-composition-system/schema" xmlns:dcsset="http://v8.1c.ru/8.1/data-composition-system/settings" xmlns:ent="http://v8.1c.ru/8.1/data/enterprise" xmlns:lf="http://v8.1c.ru/8.2/managed-application/logform" xmlns:style="http://v8.1c.ru/8.1/data/ui/style" xmlns:sys="http://v8.1c.ru/8.1/data/ui/fonts/system" xmlns:v8="http://v8.1c.ru/8.1/data/core" xmlns:v8ui="http://v8.1c.ru/8.1/data/ui" xmlns:web="http://v8.1c.ru/8.1/data/ui/colors/web" xmlns:win="http://v8.1c.ru/8.1/data/ui/colors/windows" xmlns:xr="http://v8.1c.ru/8.3/xcf/readable" xmlns:xs="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"'

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
$script:additionTags = @('SearchStringAddition','ViewStatusAddition','SearchControlAddition')
$script:tableItemTags = @('InputField','CheckBoxField','LabelField','PictureField','ColumnGroup')
$script:companionTags = @('ContextMenu','ExtendedTooltip','AutoCommandBar','SearchStringAddition','ViewStatusAddition','SearchControlAddition')
$script:dslTagMap = @{
	"radio"="RadioButtonField"; "columnGroup"="ColumnGroup"; "buttonGroup"="ButtonGroup"
	"searchString"="SearchStringAddition"; "viewStatus"="ViewStatusAddition"; "searchControl"="SearchControlAddition"
	"spreadsheet"="SpreadSheetDocumentField"; "html"="HTMLDocumentField"; "textDoc"="TextDocumentField"
	"formattedDoc"="FormattedDocumentField"; "progressBar"="ProgressBarField"; "trackBar"="TrackBarField"
	"chart"="ChartField"; "ganttChart"="GanttChartField"; "graphicalSchema"="GraphicalSchemaField"
	"planner"="PlannerField"; "periodField"="PeriodField"; "dendrogram"="DendrogramField"
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
	if ($script:barTags -contains $ct -and $script:barItemTags -notcontains $nt -and $script:additionTags -notcontains $nt) { Fail "${ctx}: в командной панели '$cl' лежат только кнопки, группы кнопок, подменю и дополнения таблицы, а '$name' — $nt" }
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

	# Эмиттеру — копия элемента без ключей позиции (это не свойства элемента)
	$el = ($op | ConvertTo-Json -Depth 100 -Compress | ConvertFrom-Json) | Select-Object -Property * -ExcludeProperty into, after, before, first
	Normalize-ElementSynonyms $el
	# Таблица динамического списка получает поведение списка, как в form-compile
	foreach ($a in $root.SelectNodes("f:Attributes/f:Attribute", $nsMgr)) {
		$t = $a.SelectSingleNode("f:Type/v8:Type", $nsMgr)
		if ($null -ne $t -and $t.InnerText.Trim() -eq 'cfg:DynamicList') { ApplyDynamicListTableHeuristic $el $a.GetAttribute('name') $true }
	}
	# Пул имён эмиттера — имена элементов формы на момент операции (без узлов событий)
	$script:seenElementNames = @{}
	foreach ($sc in (Get-ElementScopes)) {
		foreach ($n in $sc.SelectNodes(".//*[@name]")) {
			if ($n.NamespaceURI -eq $formNs -and ($n.ParentNode.LocalName -eq 'ChildItems' -or $script:companionTags -contains $n.LocalName)) {
				$script:seenElementNames[$n.GetAttribute('name')] = $true
			}
		}
	}
	$script:currentTableName = $null
	# Дополнение таблицы: источник — source или таблица, внутри которой оно лежит
	if ($script:additionTags -contains $script:dslTagMap[$typeKey]) {
		if ($el.source) {
			$src = Find-FormElement "$($el.source)"
			if ($null -eq $src -or $src.LocalName -ne 'Table') { Fail "${ctx}: source '$($el.source)' — нет такой таблицы в форме" }
			$el.source = $src.GetAttribute('name')
		} else {
			$tbl = if (Same $pos.Container $root) { $null } else { Get-NearestTable $pos.Container $true }
			if ($null -eq $tbl) { Fail "${ctx}: укажите source — таблицу, к которой относится дополнение" }
			$script:currentTableName = $tbl.GetAttribute('name')
		}
	}

	$ci = Get-OrCreateChildItems $pos.Container
	$indent = Get-ChildIndent $ci
	$script:xml = New-Object System.Text.StringBuilder 4096
	# Внутри командной панели, меню, подменю или группы кнопок кнопка — кнопка панели
	$inBar = $false
	$cur = $pos.Container
	while ($null -ne $cur -and $cur.NodeType -eq 'Element') {
		if ($script:barTags -contains $cur.LocalName) { $inBar = $true; break }
		$cur = $cur.ParentNode
	}
	X "<_F $allNsDecl>"
	Emit-Element -el $el -indent $indent -inCmdBar $inBar
	X "</_F>"
	$node = @(Import-ElementNodes (Parse-Fragment $script:xml.ToString()))[0]
	Insert-NodeAt $ci $node $pos.Ref $indent
	if ($chained) { $script:chainNode = $node }

	$pathStr = if ($op.path) { " -> $($op.path)" } else { "" }
	$evtNames = @($node.SelectNodes("f:Events/f:Event", $nsMgr) | ForEach-Object { $_.GetAttribute('name') })
	$evtStr = if ($evtNames.Count -gt 0) { " {$($evtNames -join ', ')}" } else { "" }
	$script:opLog += "  + [$($node.LocalName)] $name$pathStr$evtStr → $($pos.Desc)"
	$script:addedCount++
}

# --- Командная панель формы (autoCmdBar, как в form-compile) ---

# Кнопки из children — в командную панель формы (в конец, по порядку); autofill и horizontalAlign — её свойства.
function Invoke-AutoCmdBar($op, [int]$idx) {
	$ctx = "elements[$idx] autoCmdBar"
	$acbNode = $root.SelectSingleNode("f:AutoCommandBar", $nsMgr)
	if ($null -eq $acbNode) { Fail "${ctx}: у формы нет командной панели" }
	Assert-OpKeys $op @('autoCmdBar','children','autofill','horizontalAlign') $ctx
	if ($null -ne $op.PSObject.Properties['autofill']) {
		if (-not ($op.autofill -is [bool])) { Fail "${ctx}: autofill — true или false" }
		Set-ValueTag $acbNode 'Autofill' $(if ($op.autofill) { 'true' } else { 'false' })
		$script:opLog += "  * $($acbNode.GetAttribute('name')): Autofill=$($op.autofill.ToString().ToLower())"
	}
	if ($op.horizontalAlign) {
		Set-SimpleTag $acbNode 'HorizontalAlign' "$($op.horizontalAlign)"
		$script:opLog += "  * $($acbNode.GetAttribute('name')): HorizontalAlign=$($op.horizontalAlign)"
	}
	foreach ($child in @($op.children)) {
		if ($null -eq $child) { continue }
		if (-not ($child -is [System.Management.Automation.PSCustomObject])) { Fail "${ctx}: в children — не элемент (нужна кнопка, группа кнопок или подменю)" }
		foreach ($pk in @('into','after','before','first')) {
			if ($null -ne $child.PSObject.Properties[$pk]) { Fail "${ctx}: у кнопок в children нет позиции — они встают в конец панели по порядку; для места укажите кнопку отдельным элементом с into и after/before" }
		}
		Normalize-ElementTypeSynonyms $child
		$tk = $null
		foreach ($k in $elemTypeKeys) { if ($null -ne $child.PSObject.Properties[$k]) { $tk = $k; break } }
		if ($null -eq $tk) { Fail "${ctx}: в children — не элемент (нужна кнопка, группа кнопок или подменю)" }
		$c = $child | Select-Object -Property *
		$c | Add-Member -NotePropertyName 'into' -NotePropertyValue $acbNode.GetAttribute('name') -Force
		Invoke-Add $c $tk $idx
	}
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
	'AutoCommandBar/Autofill'='true'
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
			$evtName = "$($evt.event)"; $callType = Normalize-CallType "$($evt.callType)" $name $evtName
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
		$script:changedCount++
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
		$probeProps = [ordered]@{}
		foreach ($p in $props) {
			$key = $p.Name
			if ($key -eq 'handlers') { if (-not $op.on) { Fail "${c}: handlers задаются вместе с on" }; continue }
			if ($key -eq 'on') { Add-ElementEvents $node $p.Value $op.handlers $c; continue }
			if ($key -eq 'events') {
				if (-not ($p.Value -is [System.Management.Automation.PSCustomObject])) { Fail "${c}: events — объект { Событие: обработчик }" }
				$on = @(Get-EventPairs -el $op -elementName $n | ForEach-Object { [pscustomobject]@{ event = $_.name; handler = $_.handler; callType = $_.callType } })
				Add-ElementEvents $node $on $null $c
				continue
			}
			if ($forbidden -contains $key -or ($key -eq $script:xmlTagToDsl[$nt] -and $key -ne 'group')) {
				Fail "${c}: '$key' через set не меняется (имя и привязку не трогаем — на них ссылаются модуль и расширения; состав — через move)"
			}
			if (@('into','after','before','first') -contains $key) { Fail "${c}: '$key' — место элемента меняет move, не set" }
			if (-not $script:setProps.Contains($key)) {
				# Остальные ключи элемента — как в form-compile, через общий эмиттер
				$probeProps[$key] = $p.Value
				continue
			}
			$spec = $script:setProps[$key]
			$tag = Get-PropTag $spec $nt
			if ($null -eq $tag) { Fail "${c}: свойство '$key' к $nt не применимо; доступно: $((Get-ApplicableSetKeys $nt) -join ', ') и остальные ключи элемента из form-compile" }
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
					if ($null -eq $rmap) { Fail "${c}: свойство '$key' к $nt не применимо; доступно: $((Get-ApplicableSetKeys $nt) -join ', ') и остальные ключи элемента из form-compile" }
					$text = $rmap["$v".ToLower()]
					if (-not $text) { Fail "${c}: representation='$v' — допустимо: $(($rmap.Keys | Sort-Object) -join ', ')" }
					Set-ValueTag $node $tag $text
					$script:opLog += "  * ${n}: $tag=$text"
				}
			}
			$script:changedCount++
		}
		if ($probeProps.Count -gt 0) {
			# Контекст пробы — все свойства операции: от них зависит, как эмиттер пишет остальные
			$context = [ordered]@{}
			foreach ($p in $props) {
				if (@('on','handlers','events') -notcontains $p.Name -and $null -ne $p.Value -and -not $probeProps.Contains($p.Name)) { $context[$p.Name] = $p.Value }
			}
			Invoke-SetByEmitter $node $probeProps $context $op $c
		}
	}
}

# --- set: ключи элемента вне таблицы выше — через общий эмиттер form-compile ---
# Элемент эмитится без свойства и с ним; что различается, то свойство и пишет в XML. Так set знает
# все ключи form-compile и пишет их ровно так же, как при создании формы.

$script:probeTypeValues = @{ 'group'='vertical'; 'columnGroup'='vertical' }

function Invoke-SetProbe($node, $props) {
	$nt = $node.LocalName
	$dsl = $script:xmlTagToDsl[$nt]
	$name = $node.GetAttribute('name')
	$h = [ordered]@{}
	$h[$dsl] = if ($script:probeTypeValues.ContainsKey($dsl)) { $script:probeTypeValues[$dsl] } else { $name }
	$h['name'] = $name
	$dp = $node.SelectSingleNode("f:DataPath", $nsMgr)
	if ($null -ne $dp) { $h['path'] = $dp.InnerText }
	foreach ($k in $props.Keys) { $h[$k] = $props[$k] }
	$el = [pscustomobject]$h | ConvertTo-Json -Depth 100 -Compress | ConvertFrom-Json
	Normalize-ElementSynonyms $el
	foreach ($a in $root.SelectNodes("f:Attributes/f:Attribute", $nsMgr)) {
		$t = $a.SelectSingleNode("f:Type/v8:Type", $nsMgr)
		if ($null -ne $t -and $t.InnerText.Trim() -eq 'cfg:DynamicList') { ApplyDynamicListTableHeuristic $el $a.GetAttribute('name') $true }
	}
	$saveId = $script:nextElemId
	$script:seenElementNames = @{}
	$tbl = Get-NearestTable $node $false
	$script:currentTableName = if ($null -ne $tbl) { $tbl.GetAttribute('name') } else { $null }
	$inBar = $false
	$cur = $node.ParentNode
	while ($null -ne $cur -and $cur.NodeType -eq 'Element') {
		if ($script:barTags -contains $cur.LocalName) { $inBar = $true; break }
		$cur = $cur.ParentNode
	}
	$script:xml = New-Object System.Text.StringBuilder 4096
	X "<_F $allNsDecl>"
	$msgs = @(& { Emit-Element -el $el -indent (Get-NodeIndent $node) -inCmdBar $inBar } 3>&1 6>&1 |
		Where-Object { $_ -is [System.Management.Automation.WarningRecord] -or $_ -is [System.Management.Automation.InformationRecord] } |
		ForEach-Object { "$_" })
	X "</_F>"
	$script:nextElemId = $saveId
	$frag = Parse-Fragment $script:xml.ToString()
	$pe = $null
	foreach ($ch in $frag.DocumentElement.ChildNodes) { if ($ch.NodeType -eq 'Element') { $pe = $ch; break } }
	return @{ El = $pe; Messages = $msgs }
}

# Свойства узла: дочерние теги (без состава и событий) и атрибуты; спутники (меню, подсказка,
# панель) — отдельно, их свойства сравниваются так же.
function Get-ProbeParts($e) {
	$tags = [ordered]@{}; $comps = @{}; $attrs = @{}
	foreach ($ch in $e.ChildNodes) {
		if ($ch.NodeType -ne 'Element') { continue }
		$ln = $ch.LocalName
		if ($ln -eq 'Events') { continue }
		if ($ln -eq 'ChildItems') { $comps['#items'] = ($ch.OuterXml -replace ' id="-?\d+"', '') -replace '\s+', ' '; continue }
		if ($script:companionTags -contains $ln -and $ch.HasAttribute('name')) { $comps[$ln] = $ch; continue }
		$t = ($ch.OuterXml -replace ' id="-?\d+"', '') -replace '\s+', ' '
		if ($tags.Contains($ln)) { $tags[$ln] += $t } else { $tags[$ln] = $t }
	}
	foreach ($a in $e.Attributes) {
		if ($a.Name -ne 'name' -and $a.Name -ne 'id' -and -not $a.Name.StartsWith('xmlns')) { $attrs[$a.Name] = $a.Value }
	}
	return @{ Tags = $tags; Comps = $comps; Attrs = $attrs }
}

function Get-ProbeDiff($b, $p) {
	$pb = Get-ProbeParts $b; $pp = Get-ProbeParts $p
	$d = @{ Tags = @(); Attrs = @(); Comps = @(); Items = $false }
	foreach ($t in @($pb.Tags.Keys) + @($pp.Tags.Keys) | Select-Object -Unique) {
		if ($pb.Tags[$t] -cne $pp.Tags[$t]) { $d.Tags += $t }
	}
	foreach ($a in @($pb.Attrs.Keys) + @($pp.Attrs.Keys) | Sort-Object -Unique) {
		if ($pb.Attrs[$a] -cne $pp.Attrs[$a]) { $d.Attrs += $a }
	}
	if ($pb.Comps['#items'] -cne $pp.Comps['#items']) { $d.Items = $true }
	foreach ($cn in @($pp.Comps.Keys | Where-Object { $_ -ne '#items' } | Sort-Object)) {
		if ($null -eq $pb.Comps[$cn]) { continue }
		$sub = Get-ProbeDiff $pb.Comps[$cn] $pp.Comps[$cn]
		# Состав спутника (кнопки меню, панели) — тоже состав
		if ($sub.Items) { $d.Items = $true }
		if (Test-ProbeDiff $sub) { $d.Comps += @{ Tag = $cn; Diff = $sub } }
	}
	return $d
}

function Test-ProbeDiff($d) {
	return ($d.Tags.Count + $d.Attrs.Count + $d.Comps.Count) -gt 0 -or $d.Items
}

# Есть ли в узле хоть что-то из того, что описывает разница (для сброса к умолчанию).
function Test-ProbeDiffPresent($target, $d) {
	foreach ($t in $d.Tags) { if ($null -ne $target.SelectSingleNode("f:$t", $nsMgr)) { return $true } }
	foreach ($a in $d.Attrs) { if ($target.HasAttribute($a)) { return $true } }
	foreach ($cd in $d.Comps) {
		$tc = $target.SelectSingleNode("f:$($cd.Tag)", $nsMgr)
		if ($null -ne $tc -and (Test-ProbeDiffPresent $tc $cd.Diff)) { return $true }
	}
	return $false
}

function Get-ProbeDiffLabel($d) {
	$parts = @($d.Tags) + @($d.Attrs | ForEach-Object { "@$_" })
	foreach ($cd in $d.Comps) { $parts += @(Get-ProbeDiffLabel $cd.Diff | ForEach-Object { "$($cd.Tag)/$_" }) }
	return $parts
}

# Перенести в узел то, что различается: теги пробы заменяют свои (нет в пробе — тег убирается).
function Apply-ProbeDiff($target, $probeEl, $d, [bool]$removeOnly) {
	foreach ($t in $d.Tags) {
		foreach ($x in @($target.SelectNodes("f:$t", $nsMgr))) { Remove-NodeWithWs $x }
		if ($removeOnly) { continue }
		foreach ($pn in @($probeEl.SelectNodes("f:$t", $nsMgr))) {
			$imp = $xmlDoc.ImportNode($pn, $true)
			if ((Get-ChildRank $target.LocalName $t) -ge 0) { Insert-ChildCanonical $target $imp; continue }
			# Тега нет в корпусном порядке — встаёт перед первым следующим за ним в пробе тегом узла
			$ref = $null
			$sib = $pn.NextSibling
			while ($null -ne $sib -and $null -eq $ref) {
				if ($sib.NodeType -eq 'Element') { $ref = $target.SelectSingleNode("f:$($sib.LocalName)", $nsMgr) }
				$sib = $sib.NextSibling
			}
			Insert-NodeAt $target $imp $ref (Get-ChildIndent $target)
		}
	}
	foreach ($a in $d.Attrs) {
		if (-not $removeOnly -and $probeEl.HasAttribute($a)) { $target.SetAttribute($a, $probeEl.GetAttribute($a)) }
		else { $target.RemoveAttribute($a) }
	}
	foreach ($cd in $d.Comps) {
		$tc = $target.SelectSingleNode("f:$($cd.Tag)", $nsMgr)
		$pc = if ($null -ne $probeEl) { $probeEl.SelectSingleNode("f:$($cd.Tag)", $nsMgr) } else { $null }
		if ($null -ne $tc) { Apply-ProbeDiff $tc $pc $cd.Diff $removeOnly }
		elseif (-not $removeOnly) { Fail "у '$($target.GetAttribute('name'))' нет $($cd.Tag) — свойство некуда записать" }
	}
}

function Get-ProbeOwnerTags([string]$key) {
	foreach ($g in $script:genericScalars) { if ($g.Key -eq $key) { return @($g.Tag) } }
	if ($script:appearanceSpec.ContainsKey($key)) { return @($script:appearanceSpec[$key].tag) }
	return @()
}

# Теги, которые set через эмиттер не трогает: привязка и тип. Теги ручной таблицы (Title, ToolTip…)
# проба переписывает, только если их ключ задан в той же операции, — иначе эмиттер, не зная их
# значения, затёр бы его своим.
$script:probeLockedTags = @('DataPath','CommandName','Type')

function Assert-ProbeTags($d, [string]$k, $op, [string]$c) {
	foreach ($t in $d.Tags) {
		if ($script:probeLockedTags -contains $t) { Fail "${c}: '$k' меняет $t — привязка и тип элемента через set не меняются" }
	}
	foreach ($t in $d.Tags) {
		$owners = @($script:setProps.Keys | Where-Object { $script:setProps[$_].Tags -contains $t })
		if ($owners.Count -gt 0 -and -not ($owners | Where-Object { $null -ne $op.PSObject.Properties[$_] })) {
			Fail "${c}: '$k' меняет и $t — укажите в той же операции $($owners -join ' или ')"
		}
	}
}

function Invoke-SetByEmitter($node, $props, $context, $op, [string]$c) {
	$n = $node.GetAttribute('name')
	$nt = $node.LocalName
	if (-not $script:xmlTagToDsl.ContainsKey($nt)) { Fail "${c}: у $nt меняются только: $((Get-ApplicableSetKeys $nt) -join ', ')" }
	$set = [ordered]@{}
	foreach ($k in $context.Keys) { $set[$k] = $context[$k] }
	foreach ($k in $props.Keys) { if ($null -ne $props[$k]) { $set[$k] = $props[$k] } }
	$full = Invoke-SetProbe $node $set
	if ($full.El.LocalName -ne $nt) {
		$tk = @($props.Keys | Where-Object { $script:dslTagMap.ContainsKey($_) })
		Fail "${c}: '$($tk -join ', ')' — ключ типа элемента; тип через set не меняется"
	}
	$removals = @()
	$applies = @()
	foreach ($k in $props.Keys) {
		$v = $props[$k]
		$rest = [ordered]@{}
		foreach ($k2 in $set.Keys) { if ($k2 -ne $k) { $rest[$k2] = $set[$k2] } }
		$without = Invoke-SetProbe $node $rest
		if ($null -eq $v) {
			# Сброс: убрать то, что ключ пишет при любом значении
			$owned = @(Get-ProbeOwnerTags $k)
			$d = @{ Tags = $owned; Attrs = @(); Comps = @(); Items = $false }
			if ($owned.Count -eq 0) {
				foreach ($alt in @($true, $false)) {
					$wa = [ordered]@{}; foreach ($k2 in $rest.Keys) { $wa[$k2] = $rest[$k2] }; $wa[$k] = $alt
					$pa = Invoke-SetProbe $node $wa
					if (@($pa.Messages | Where-Object { $_ -match "unknown key '" }).Count -gt 0) { break }
					$da = Get-ProbeDiff $without.El $pa.El
					if (Test-ProbeDiff $da) { $d = $da; break }
				}
			}
			if (-not (Test-ProbeDiff $d)) { Fail "${c}: '$k' сбросить нельзя — неизвестное свойство или у него нет значения по умолчанию; укажите значение" }
			Assert-ProbeTags $d $k $op $c
			if (Test-ProbeDiffPresent $node $d) {
				$removals += $d
				$script:opLog += "  * ${n}: $k сброшено"
				$script:changedCount++
			} else {
				$script:opLog += "  = ${n}: $k — уже по умолчанию"
			}
			continue
		}
		$d = Get-ProbeDiff $without.El $full.El
		if (Test-ProbeDiff $d) {
			if ($d.Items) { Fail "${c}: '$k' меняет состав '$n' — элементы добавляются отдельными операциями" }
			Assert-ProbeTags $d $k $op $c
			$applies += $d
			$shown = if ($v -is [bool]) { "=$("$v".ToLower())" } elseif ($v -is [string] -or $v -is [int] -or $v -is [long]) { "=$v" } else { "" }
			$script:opLog += "  * ${n}: $k$shown → $((Get-ProbeDiffLabel $d) -join ', ')"
			$script:changedCount++
			continue
		}
		# Разницы нет: ключ неизвестен, значение не распознано или совпадает с умолчанием платформы
		$msgs = @($full.Messages)
		if (@($msgs | Where-Object { $_ -match "unknown key '$([regex]::Escape($k))'" }).Count -gt 0) {
			Fail "${c}: неизвестное свойство '$k' — ключи те же, что у элемента в form-compile"
		}
		$vv = @($msgs | ForEach-Object { if ($_ -match 'Valid values: (.*?)\. Value ignored') { $Matches[1] } })
		if ($vv.Count -gt 0) { Fail "${c}: $k='$v' — значение не распознано; допустимо: $($vv[0])" }
		if ($v -is [bool]) {
			$wa = [ordered]@{}; foreach ($k2 in $rest.Keys) { $wa[$k2] = $rest[$k2] }; $wa[$k] = -not $v
			$pa = Invoke-SetProbe $node $wa
			$da = Get-ProbeDiff $without.El $pa.El
			if (Test-ProbeDiff $da) {
				Assert-ProbeTags $da $k $op $c
				if (Test-ProbeDiffPresent $node $da) {
					$removals += $da
					$script:opLog += "  * ${n}: $k=$("$v".ToLower()) — умолчание платформы, $((Get-ProbeDiffLabel $da) -join ', ') не пишется"
					$script:changedCount++
				} else {
					$script:opLog += "  = ${n}: $k=$("$v".ToLower()) — уже по умолчанию"
				}
				continue
			}
		}
		Fail "${c}: '$k' к $nt не применимо или значение совпадает с умолчанием (чтобы вернуть умолчание — null)"
	}
	foreach ($r in $removals) { Apply-ProbeDiff $node $null $r $true }
	foreach ($a in $applies) { Apply-ProbeDiff $node $full.El $a $false }
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

# Ключи типов — в порядке form-compile: ключ, который бывает и свойством (group у страницы,
# picture у кнопки), проверяется после типа, у которого он свойство.
$elemTypeKeys = @("columnGroup","buttonGroup","pages","page","group","input","check","radio","label","labelField","table","button","calendar","cmdBar","popup","searchString","viewStatus","searchControl","picField","picture","spreadsheet","html","textDoc","formattedDoc","progressBar","trackBar","chart","ganttChart","graphicalSchema","planner","periodField","dendrogram")

if ($def.elements -and @($def.elements).Count -gt 0) {
	$ops = @($def.elements)

	# Вид каждой операции: ключ типа — добавление, move/set — над существующим элементом.
	$opKinds = @()
	for ($i = 0; $i -lt $ops.Count; $i++) {
		$op = $ops[$i]
		$kinds = @()
		foreach ($k in @('move','set','remove')) { if ($null -ne $op.PSObject.Properties[$k]) { $kinds += $k } }
		# Тип элемента XML-именем или по-русски (InputField, ПолеВвода) → канонический ключ
		if ($kinds.Count -eq 0 -and $op -is [System.Management.Automation.PSCustomObject]) { Normalize-ElementTypeSynonyms $op }
		# У set ключ типа — свойство (group — ориентация); остальные ключи типа set отвергнет сам.
		if ($kinds -notcontains 'set') {
			if ($null -ne $op.PSObject.Properties['autoCmdBar']) { $kinds += 'autoCmdBar' }
			else { foreach ($k in $elemTypeKeys) { if ($null -ne $op.PSObject.Properties[$k]) { $kinds += $k; break } } }
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
		if ($opKinds[$i] -in @('move','set','remove','autoCmdBar')) { continue }
		Walk-ElemNames $ops[$i] $dslElemNames
	}

	$startElemId = $script:nextElemId
	for ($i = 0; $i -lt $ops.Count; $i++) {
		switch ($opKinds[$i]) {
			'move' { Invoke-Move $ops[$i] $i }
			'set'  { Invoke-Set $ops[$i] $i }
			'remove' { Invoke-Remove $ops[$i] $i }
			'autoCmdBar' { Invoke-AutoCmdBar $ops[$i] $i }
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
