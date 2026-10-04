---
name: form-edit
description: Добавление, перенос, изменение и удаление элементов, реквизитов и команд существующей управляемой формы 1С, правка заголовка, свойств, событий и оформления формы. Используй когда нужно точечно модифицировать готовую форму
argument-hint: <FormPath> <JsonPath>
allowed-tools:
  - Bash
  - Read
  - Write
  - Glob
---

# /form-edit — Редактирование формы

Правит существующий `Form.xml`: добавляет, переносит, меняет и удаляет элементы; добавляет и удаляет реквизиты, команды и параметры; меняет заголовок, свойства, события, условное оформление и командный интерфейс формы. Остальное в файле не трогает. Перенесённый или изменённый элемент сохраняет свой id — обработчики и обращения из модуля остаются рабочими.

## Параметры

| Параметр  | Обязательный | Описание                         |
|-----------|:------------:|----------------------------------|
| FormPath  | да           | Путь к существующему Form.xml    |
| JsonPath  | да           | Путь к JSON с описанием правок   |

## Команда

```powershell
powershell.exe -NoProfile -File "${CLAUDE_SKILL_DIR}/scripts/form-edit.ps1" -FormPath "<путь>" -JsonPath "<путь>"
```

## Правки

```json
{
  "elements": [ ... ],
  "attributes": [ ... ],
  "commands": [ ... ],
  "parameters": [ ... ],
  "title": "Заголовок формы",
  "properties": { "windowOpeningMode": "LockOwnerWindow" },
  "events": { "OnOpen": "ПриОткрытии" },
  "excludedCommands": [ "Copy" ],
  "conditionalAppearance": [ ... ],
  "commandInterface": { ... }
}
```

Все ключи необязательны. Сначала выполняются `elements`, затем `attributes`, `commands` и остальное: элемент, привязанный к удаляемому реквизиту, удаляют в `elements` той же правки. Процедуры обработчиков в модуле формы не создаются — их добавляют в `Module.bsl` отдельно.

### Элементы: добавить, перенести, изменить, удалить

`elements` — список операций, выполняется по порядку. Вид операции задаёт ключ:

| Ключ | Операция |
|------|----------|
| тип элемента (`input`, `group`, `table`, …) | Добавить новый элемент (ключи — DSL ниже) |
| `move` | Перенести существующий |
| `set` | Изменить свойства существующего |
| `remove` | Удалить |
| `autoCmdBar` | Командная панель формы: `children` — добавить кнопки, `autofill`, `horizontalAlign` |

Позиция задаётся у каждой операции:

| Ключи | Куда |
|-------|------|
| `after: "X"` / `before: "X"` | Рядом с X, в его группе |
| `into: "G"` | В конец группы, страницы или таблицы G |
| `into: "G", first: true` | В начало G |

Без своей позиции новый элемент встаёт по `into`/`after`, заданным в корне JSON рядом с `elements` (общие для всех таких элементов; следующий встаёт за предыдущим), а без них — в конец формы.

```json
{
  "attributes": [ { "name": "Срочно", "type": "boolean" } ],
  "elements": [
    { "group": "alwaysHorizontal", "name": "ГруппаОтгрузка", "after": "Контрагент" },
    { "move": ["Склад", "Организация"], "into": "ГруппаОтгрузка" },
    { "check": "Срочно", "path": "Срочно", "into": "ГруппаОтгрузка" },
    { "move": "ТоварыСумма", "before": "ТоварыЦена" },
    { "set": "Ответственный", "visible": false },
    { "set": "Контрагент", "title": "Покупатель", "textColor": "style:SpecialTextColor",
      "events": { "OnChange": null } },
    { "remove": "Комментарий" }
  ]
}
```

- `move` — имя или список имён (встают подряд в указанном порядке); позиция обязательна. Элемент переносится целиком, со вложенными элементами.
- `set` — имя или список имён и ключи элемента из DSL ниже: заголовок, видимость, размеры, цвета и шрифт, параметры выбора и т. д. `null` возвращает значение по умолчанию. `events` добавляет обработчики. Имя, тип элемента, путь к данным и команду кнопки `set` не меняет.
- `remove` — имя или список имён; группа, страница или таблица удаляются вместе с содержимым.

### Форма

| Ключ | Что делает |
|------|-----------|
| `title` | Заголовок формы (строка или `{ru, en}`); `null` — убрать |
| `properties` | Свойства формы (`references/form-properties.md`); `null` у свойства — убрать |
| `events` | Обработчики событий формы: `{ "OnOpen": "ПриОткрытии" }` |
| `excludedCommands` | Исключить стандартные команды: `["Copy"]`; вернуть: `{ "remove": ["Copy"] }` |
| `attributes` / `commands` / `parameters` | Добавить — ключи DSL ниже; удалить — запись `{ "remove": "Имя" }` (или список имён) |
| `conditionalAppearance` | Добавить правила условного оформления (`references/appearance.md`) |
| `commandInterface` | Добавить команды в панели формы (`references/command-interface.md`) |

```json
{
  "elements":   [ { "remove": "Срочно" } ],
  "attributes": [ { "remove": "Срочно" } ],
  "commands":   [ { "remove": "Рассчитать" } ]
}
```

### Форма расширения

Форма расширения (с `<BaseForm>`) распознаётся сама. Обработчику указывают вид вызова — `callType`: `Before`, `After` или `Override`:

```json
{
  "events": { "OnCreateAtServer": { "handler": "Расш1_ПриСозданииПосле", "callType": "After" } },
  "elements": [
    { "set": "Банк", "events": { "OnChange": { "handler": "Расш1_БанкПриИзменении", "callType": "Before" } } }
  ],
  "commands": [
    { "name": "Подбор", "action": "Расш1_ПодборПосле", "callType": "After" },
    { "name": "Запрос", "actions": [
      { "handler": "Расш1_ЗапросПеред", "callType": "Before" },
      { "handler": "Расш1_ЗапросПосле", "callType": "After" } ] }
  ]
}
```

## DSL элементов, реквизитов и команд

Ключи — те же, что в `/form-compile`: и при добавлении, и в `set`.

### Элементы (ключ определяет тип)

| Ключ | Элемент | Значение ключа |
|------|---------|----------------|
| `group` | Обычная группа | ориентация: `vertical` / `horizontalIfPossible` / `alwaysHorizontal` |
| `input` | Поле ввода | имя |
| `check` | Флажок | имя |
| `radio` | Переключатель | имя |
| `label` | Надпись | имя (текст — в `title`) |
| `labelField` | Поле-надпись (значение без редактирования) | имя |
| `table` | Таблица | имя |
| `columnGroup` | Группа колонок (внутри `columns` таблицы) | `horizontal` / `vertical` / `inCell` |
| `pages` / `page` | Страницы / страница | имя |
| `button` | Кнопка | имя |
| `buttonGroup` | Группа кнопок (в командной панели или подменю) | имя |
| `popup` | Подменю | имя |
| `cmdBar` | Командная панель в раскладке формы | имя |
| `autoCmdBar` | Командная панель самой формы | имя (обычно `ФормаКоманднаяПанель`) |
| `picture` | Картинка | имя |
| `picField` | Поле-картинка | имя |

Табличный документ, HTML, календарь, диаграммы и другие особые поля — по индексу ниже.

### Общие свойства элементов

| Ключ | Описание |
|------|----------|
| `name` | Имя элемента, если отличается от значения ключа типа. Имена в форме уникальны |
| `title` | Заголовок (строка или `{ru, en}`); `""` — без заголовка |
| `tooltip` | Всплывающая подсказка |
| `visible: false` / `enabled: false` / `readOnly: true` | Скрыть / сделать недоступным / только чтение |
| `titleLocation` | `none` / `left` / `right` / `top` / `bottom` / `auto` |
| `width` / `height` | Размер |
| `horizontalStretch` / `verticalStretch` | Растягивать |
| `autoMaxWidth: false` | Снять предел ширины (поле тянется на всю доступную ширину) |
| `events` | Обработчики: `{ "OnChange": "ИмяОбработчика" }`; `null` вместо имени — имя по шаблону `<Элемент><Событие>` |

### События

Имена регистрозависимы.

**Форма:** `OnCreateAtServer`, `OnOpen`, `BeforeClose`, `OnClose`, `NotificationProcessing`, `ChoiceProcessing`, `OnReadAtServer`, `BeforeWriteAtServer`, `OnWriteAtServer`, `AfterWriteAtServer`, `BeforeWrite`, `AfterWrite`, `FillCheckProcessingAtServer`, `BeforeLoadDataFromSettingsAtServer`, `OnLoadDataFromSettingsAtServer`, `ExternalEvent`, `Opening`

**input:** `OnChange`, `StartChoice`, `ChoiceProcessing`, `AutoComplete`, `TextEditEnd`, `Clearing`, `Creating`, `EditTextChange`
**picField:** `OnChange`, `StartChoice`, `ChoiceProcessing`, `Click`, `Clearing`
**check / radio:** `OnChange`
**table:** `OnStartEdit`, `OnEditEnd`, `OnChange`, `Selection`, `ValueChoice`, `BeforeAddRow`, `BeforeDeleteRow`, `AfterDeleteRow`, `BeforeRowChange`, `BeforeEditEnd`, `OnActivateRow`, `OnActivateCell`, `Drag`, `DragStart`, `DragCheck`, `DragEnd`
**label:** `Click`, `URLProcessing`
**picture:** `Click`
**labelField:** `OnChange`, `StartChoice`, `ChoiceProcessing`, `Click`, `URLProcessing`, `Clearing`
**button:** `Click`
**pages:** `OnCurrentPageChange`

### Поле ввода (input)

| Ключ | Описание |
|------|----------|
| `path` | Путь к данным: `"Объект.Организация"`, `"ИмяРеквизита"` |
| `multiLine: true` | Многострочное (комментарий) |
| `choiceButton` / `clearButton` / `dropListButton` | Кнопки выбора, очистки, выпадающего списка |
| `markIncomplete: true` | Подсвечивать незаполненное |
| `inputHint` | Подсказка в пустом поле |
| `skipOnInput: true` | Пропускать при переходе по Enter/Tab |
| `maxWidth` | Предел ширины |

Список выбора, маска, формат, пароль и другие кнопки — `references/input-fields.md`.

### Флажок (check) и переключатель (radio)

`check`: `path`, `titleLocation` (по умолчанию заголовок справа). Вид «выключатель» или «тумблер» — `references/input-fields.md`.

`radio`: `path`, `radioButtonType` (`Auto` / `RadioButtons` / `Tumbler`), `columnsCount`, `choiceList`:

```json
{ "radio": "СпособКурса", "path": "Объект.СпособУстановкиКурса", "radioButtonType": "Tumbler",
  "choiceList": [
    { "value": "Enum.СпособыКурса.EnumValue.Авто",   "presentation": "Автоматически" },
    { "value": "Enum.СпособыКурса.EnumValue.Ручной", "presentation": { "ru": "Вручную", "en": "Manual" } }
  ] }
```

`value` — строка, число, булево или значение перечисления `"Enum.Тип.EnumValue.Значение"`; `presentation` — текст варианта.

### Надпись (label) и поле-надпись (labelField)

`label`: `title` — текст (поддерживает разметку, см. `references/tooltips-text.md`), `hyperlink: true` — ссылка.
`labelField`: `path`, `hyperlink: true` — значение как ссылка.

### Группа (group)

| Ключ | Описание |
|------|----------|
| `behavior` | `collapsible` — сворачиваемая, `popup` — всплывающая; не указан — обычная |
| `showTitle: true` | Показывать заголовок |
| `representation` | `none` / `normal` / `weak` / `strong` — рамка группы |
| `united: false` | Выравнивать поля только внутри группы, а не вместе с соседними |
| `children` | Вложенные элементы |

Свёрнутая при открытии группа, интервалы, заголовок из данных — `references/groups-pages.md`.

### Таблица (table)

Таблица привязывается к реквизиту-таблице (`ValueTable`, табличная часть объекта, динамический список) — см. «Связка элемент + реквизит».

| Ключ | Описание |
|------|----------|
| `path` | Путь к реквизиту-таблице |
| `columns` | Колонки — элементы (`input`, `check`, `labelField`, `picField`, `columnGroup`); путь колонки — путь таблицы плюс имя колонки: `Объект.Товары.Сумма`, `Данные.Сумма` |
| `changeRowSet: true` / `changeRowOrder: true` | Разрешить добавлять/удалять / перемещать строки |
| `header: false` | Без шапки |
| `heightInTableRows` | Высота в строках |
| `commandBarLocation` | `None` / `Top` / `Bottom` / `Auto` |
| `searchStringLocation` | `None` / `Top` / `Bottom` / `CommandBar` / `Auto` |
| `choiceMode: true` | Таблица выбора (форма выбора) |

Подвал с итогами, дерево, выделение, закрепление колонок, перетаскивание — `references/table-advanced.md`.

`columnGroup` группирует колонки: `title`, `showInHeader`, `children`; `inCell` — несколько колонок в одной ячейке:

```json
{ "table": "Список", "path": "Список", "columns": [
    { "columnGroup": "horizontal", "name": "ГруппаСрок", "title": "Срок", "children": [
        { "input": "ДатаНачала", "path": "Список.ДатаНачала" },
        { "input": "ДатаОкончания", "path": "Список.ДатаОкончания" } ] },
    { "input": "Комментарий", "path": "Список.Комментарий" }
] }
```

### Страницы (pages + page)

`pages`: `pagesRepresentation` (`TabsOnTop` / `TabsOnBottom` / `None` — без закладок), `children` — массив `page`.
`page`: `title`, `group` (ориентация содержимого), `children`.

### Кнопки и командные панели

| Ключ (button) | Описание |
|---------------|----------|
| `command` | Команда формы → `Form.Command.Имя` |
| `stdCommand` | Стандартная: `"Close"`; с точкой — команда элемента: `"Товары.Add"` |
| `defaultButton: true` | Кнопка по умолчанию |
| `type` | `usual` / `hyperlink` |
| `representation` | `Auto` / `Text` / `Picture` / `PictureAndText` |
| `locationInCommandBar` | `InCommandBar` / `InAdditionalSubmenu` |

`autoCmdBar` — командная панель формы, сюда помещают основные действия:

```json
{ "autoCmdBar": "ФормаКоманднаяПанель", "children": [
    { "button": "Загрузить", "command": "Загрузить", "defaultButton": true },
    { "popup": "Печать", "title": "Печать", "children": [
        { "button": "ПечатьСчета", "command": "ПечатьСчета" } ] },
    { "buttonGroup": "ГруппаПеремещение", "children": [
        { "button": "Вверх", "command": "Вверх" },
        { "button": "Вниз", "command": "Вниз" } ] }
] }
```

- `popup` — подменю: `title`, `children`.
- `buttonGroup` — кнопки, объединённые в группу: `title`, `children`.
- `cmdBar` — отдельная панель в раскладке формы: `autofill`, `children`.
- `autoCmdBar`: `autofill: false` — без стандартных команд, `horizontalAlign` — выравнивание.

Картинки кнопок, кнопки-переключатели, команды таблицы в группе кнопок, своё контекстное меню у элемента — `references/buttons-commands.md`.

### Картинка (picture) и поле-картинка (picField)

`picture`: `src` — `"StdPicture.X"` / `"CommonPicture.X"`, `width`, `height`.
`picField`: `path`; для булева или числа — `valuesPicture` (иначе значок не рисуется). Подробнее — `references/pictures.md`.

### Реквизиты (attributes)

```json
{ "name": "Объект", "type": "DataProcessorObject.Загрузка", "main": true }
{ "name": "Итого", "type": "decimal(15,2)", "title": "Итого" }
{ "name": "Таблица", "type": "ValueTable", "columns": [
    { "name": "Номенклатура", "type": "CatalogRef.Номенклатура" },
    { "name": "Количество", "type": "decimal(10,3)" } ] }
{ "name": "Список", "type": "DynamicList", "main": true,
  "settings": { "mainTable": "Catalog.Номенклатура" } }
```

- `main: true` — основной реквизит формы (объект, набор записей, динамический список)
- `savedData: true` — сохраняемые данные (у основного реквизита-объекта ставится само)
- `columns` — колонки `ValueTable` / `ValueTree`
- `settings` — настройки динамического списка (`references/dynamic-list.md`)

Сохранение в настройках, проверка заполнения, функциональные опции — `references/attributes-advanced.md`.

### Команды (commands) и параметры (parameters)

```json
"commands": [ { "name": "Загрузить", "action": "ЗагрузитьОбработка", "title": "Загрузить", "shortcut": "Ctrl+Enter", "picture": "StdPicture.Refresh" } ]
"parameters": [ { "name": "Основание", "type": "DocumentRef.Заказ" } ]
```

Команды: `name`, `action` (процедура-обработчик), `title`, `shortcut`, `picture`. Параметры: `name`, `type`, `key: true` — ключевой.

### Система типов

| DSL | Тип |
|-----|-----|
| `string` / `string(100)` | Строка (неограниченная / длины 100) |
| `decimal(15,2)` / `decimal(10,0,nonneg)` | Число / неотрицательное |
| `boolean` | Булево |
| `date` / `dateTime` / `time` | Дата / дата и время / время |
| `CatalogRef.X` / `DocumentRef.X` / `EnumRef.X` / … | Ссылки |
| `CatalogObject.X` / `DocumentObject.X` / `DataProcessorObject.X` / `ReportObject.X` | Объекты (основной реквизит) |
| `InformationRegisterRecordSet.X` / `AccumulationRegisterRecordSet.X` | Наборы записей |
| `ValueTable` / `ValueTree` / `ValueList` | Таблица / дерево / список значений |
| `DynamicList` | Динамический список |
| `TypeDescription`, `UUID`, `FormattedString`, `Picture`, `Color`, `Font`, `DataCompositionSettings`, `StandardPeriod`, `mxl:SpreadsheetDocument` | Платформенные |
| `Тип1 \| Тип2` | Составной |

Также `ChartOfAccountsRef/Object`, `ChartOfCharacteristicTypesRef/Object`, `ChartOfCalculationTypesRef/Object`, `ExchangePlanRef/Object`, `BusinessProcessRef/Object`, `TaskRef/Object`, `AccountingRegisterRecordSet`, `InformationRegisterRecordManager`, `ConstantsSet`. Наборы типов — `references/type-system-advanced.md`.

> `FormDataStructure`, `FormDataCollection`, `FormDataTree` — не типы реквизита (ошибка при загрузке). Вместо них — объектный тип (`DocumentObject.X`…), `ValueTable`, `ValueTree`.

## Связка элемент + реквизит

Элемент показывает данные реквизита через `path`.

Табличная часть основного реквизита — путь `Объект.<ТЧ>`, колонки — `Объект.<ТЧ>.<Реквизит>`:

```json
{ "table": "Товары", "path": "Объект.Товары", "columns": [
    { "input": "ТоварыНоменклатура", "path": "Объект.Товары.Номенклатура" },
    { "input": "ТоварыКоличество", "path": "Объект.Товары.Количество" } ] }
```

Таблица на реквизите формы — реквизит `ValueTable` с колонками:

```json
{
  "elements": [
    { "table": "Данные", "path": "Данные", "changeRowSet": true, "columns": [
        { "input": "ДанныеДата", "path": "Данные.Дата" },
        { "input": "ДанныеСумма", "path": "Данные.Сумма" } ] }
  ],
  "attributes": [
    { "name": "Данные", "type": "ValueTable", "columns": [
        { "name": "Дата", "type": "date" },
        { "name": "Сумма", "type": "decimal(15,2)" } ] }
  ]
}
```

## Задача → справочник

Описанного выше хватает для большинства форм. Под задачу подгрузите файл из `references/`:

| Задача | Справочник |
|--------|-----------|
| Список выбора, быстрый выбор, своя форма выбора, маска, формат числа, пароль, выключатель/тумблер, кнопки открытия и создания, поле составного типа | `input-fields.md` |
| Ограничить выбор отбором, связать поле с другим полем, связь по типу | `choice-params.md` |
| Свёрнутая группа, интервалы и ширины колонок в группе, заголовок группы или страницы из данных, значок закладки, мастер по шагам (страницы без закладок) | `groups-pages.md` |
| Итоги в подвале таблицы, дерево, выделение нескольких строк, закрепление колонок, поиск, перетаскивание, убрать стандартные команды таблицы | `table-advanced.md` |
| Форма списка: источник данных, запрос, отбор, сортировка, группировка, иерархия | `dynamic-list.md` |
| Кнопка с картинкой, переключатель в панели, команды таблицы в группе кнопок, своё контекстное меню или панель у поля, команда для текущей строки таблицы | `buttons-commands.md` |
| Подсветить цветом, шрифт, рамка, условное оформление (в форме списка — `dynamic-list.md`) | `appearance.md` |
| Расширенная подсказка под полем, текст с выделением или ссылкой | `tooltips-text.md` |
| Картинка, значок в колонке, иконка по значению | `pictures.md` |
| Печатная форма или отчёт на форме (табличный документ) | `spreadsheet.md` |
| HTML, текстовый документ, индикатор, ползунок, календарь, период | `special-fields.md` |
| Диаграмма, диаграмма Ганта, планировщик | `charts.md` |
| Модальность, размер, прокрутка, Enter, свойства формы документа (время, проведение) | `form-properties.md` |
| Форма отчёта (СКД) | `report-form.md` |
| Сохранить значение в настройках, проверка заполнения, функциональные опции, тип элементов списка значений | `attributes-advanced.md` |
| Видимость и доступ по ролям | `roles-access.md` |
| Командный интерфейс формы (переходы, важные команды) | `command-interface.md` |
| Выравнивание, предел размера, фокус по умолчанию, узкие экраны | `layout-advanced.md` |
| Наборы и составные типы | `type-system-advanced.md` |

## Workflow

1. `/form-info` — посмотреть структуру формы: имена элементов, реквизиты, команды.
2. Описать правки в JSON.
3. `/form-edit` — применить; в выводе — что добавлено, перенесено, изменено и удалено.
4. `/form-validate` — проверить форму.
