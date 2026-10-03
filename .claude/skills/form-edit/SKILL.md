---
name: form-edit
description: Добавление, перенос и изменение элементов формы, добавление реквизитов и команд в существующую управляемую форму 1С. Используй когда нужно точечно модифицировать готовую форму
argument-hint: <FormPath> <JsonPath>
allowed-tools:
  - Bash
  - Read
  - Write
  - Glob
---

# /form-edit — Редактирование формы

Добавляет элементы, реквизиты и/или команды в существующий Form.xml, переставляет и меняет уже существующие элементы. Автоматически выделяет ID из правильного пула, генерирует companion-элементы (ContextMenu, ExtendedTooltip, и др.) и обработчики событий. Перенесённый элемент сохраняет свой id, поэтому обработчики, условное оформление и ссылки из модуля остаются рабочими.

## Использование

```
/form-edit <FormPath> <JsonPath>
```

## Параметры

| Параметр  | Обязательный | Описание                         |
|-----------|:------------:|----------------------------------|
| FormPath  | да           | Путь к существующему Form.xml    |
| JsonPath  | да           | Путь к JSON с описанием добавлений |

## Команда

```powershell
powershell.exe -NoProfile -File "${CLAUDE_SKILL_DIR}/scripts/form-edit.ps1" -FormPath "<путь>" -JsonPath "<путь>"
```

## JSON формат

```json
{
  "elements": [
    { "input": "Склад", "path": "Объект.Склад", "after": "Контрагент", "on": ["OnChange"] }
  ],
  "attributes": [
    { "name": "СуммаИтого", "type": "decimal(15,2)" }
  ],
  "commands": [
    { "name": "Рассчитать", "action": "РассчитатьОбработка" }
  ]
}
```

`elements` — список операций над деревом элементов, выполняется по порядку. Вид операции задаёт ключ: тип элемента (`input`, `group`, …) — добавить новый, `move` — переставить существующий, `set` — изменить существующий. `attributes` и `commands` добавляются независимо от порядка.

### Расширения (extension-формы)

Для заимствованных форм (с `<BaseForm>`) автоматически активируется extension-режим: ID начинаются с 1000000+. Доступны дополнительные секции:

```json
{
  "formEvents": [
    { "name": "OnCreateAtServer", "handler": "Расш1_ПриСозданииПосле", "callType": "After" },
    { "name": "OnOpen", "handler": "Расш1_ПриОткрытии", "callType": "Before" }
  ],
  "elementEvents": [
    { "element": "Банк", "name": "OnChange", "handler": "Расш1_БанкПриИзменении", "callType": "Before" }
  ],
  "commands": [
    { "name": "Подбор", "action": "Расш1_ПодборПосле", "callType": "After" },
    { "name": "Запрос", "actions": [
      { "callType": "Before", "handler": "Расш1_ЗапросПеред" },
      { "callType": "After", "handler": "Расш1_ЗапросПосле" }
    ]}
  ],
  "elements": [
    { "input": "Поле", "path": "Объект.Поле", "on": [{ "event": "OnChange", "callType": "After" }] }
  ]
}
```

### Позиционирование элементов

Позиция задаётся у каждой операции:

| Ключи | Куда |
|-------|------|
| `after: "X"` / `before: "X"` | рядом с X, в его группе |
| `into: "G"` | в конец группы/страницы/таблицы G |
| `into: "G", first: true` | в начало G |

Без своей позиции новый элемент встаёт по верхнеуровневым `into`/`after` (общие для всех таких элементов, следующий — за предыдущим), иначе — в конец формы.

### Существующие элементы: move и set

```json
{
  "attributes": [ { "name": "Срочно", "type": "boolean" } ],
  "elements": [
    { "group": "alwaysHorizontal", "name": "ГруппаОтгрузка", "after": "Контрагент", "showTitle": false },
    { "move": ["Склад", "Организация"], "into": "ГруппаОтгрузка" },
    { "check": "Срочно", "path": "Срочно", "into": "ГруппаОтгрузка" },
    { "move": "ТоварыСумма", "before": "ТоварыЦена" },
    { "set": "Ответственный", "visible": false },
    { "set": "Контрагент", "title": "Покупатель", "on": ["OnChange"] }
  ]
}
```

- `move` — имя или список имён (встают подряд в указанном порядке); позиция обязательна. Элемент переносится целиком, со своими вложенными элементами.
- `set` — имя или список имён и свойства с теми же ключами, что при создании элемента (`title`, `tooltip`, `visible`, `enabled`, `readOnly`, `titleLocation`, `width`, `group`, `representation`, `showTitle` и др.). `null` сбрасывает свойство к значению по умолчанию. `on` добавляет обработчики событий в том же формате, что у нового элемента.
- Имя элемента и привязку к данным (`path`) `set` не меняет.

### Типы элементов

Те же DSL-ключи, что в `/form-compile`:

| Ключ | XML тег | Companions |
|------|---------|------------|
| `input` | InputField | ContextMenu, ExtendedTooltip |
| `check` | CheckBoxField | ContextMenu, ExtendedTooltip |
| `label` | LabelDecoration | ContextMenu, ExtendedTooltip |
| `labelField` | LabelField | ContextMenu, ExtendedTooltip |
| `group` | UsualGroup | ExtendedTooltip |
| `table` | Table | ContextMenu, AutoCommandBar, Search*, ViewStatus* |
| `pages` | Pages | ExtendedTooltip |
| `page` | Page | ExtendedTooltip |
| `button` | Button | ExtendedTooltip |

Группы и таблицы поддерживают `children`/`columns` для вложенных элементов.

### Кнопки: command и stdCommand

- `"command": "ИмяКоманды"` → `Form.Command.ИмяКоманды`
- `"stdCommand": "Close"` → `Form.StandardCommand.Close`
- `"stdCommand": "Товары.Add"` → `Form.Item.Товары.StandardCommand.Add` (стандартная команда элемента)

### Допустимые события (`on`)

Компилятор предупреждает об ошибках в именах событий. Основные:

- **input**: `OnChange`, `StartChoice`, `ChoiceProcessing`, `Clearing`, `AutoComplete`, `TextEditEnd`
- **check**: `OnChange`
- **table**: `OnStartEdit`, `OnEditEnd`, `OnChange`, `Selection`, `BeforeAddRow`, `BeforeDeleteRow`, `OnActivateRow`
- **label/picture**: `Click`, `URLProcessing`
- **pages**: `OnCurrentPageChange`
- **button**: `Click`

### Система типов (для attributes)

`string`, `string(100)`, `decimal(15,2)`, `boolean`, `date`, `dateTime`, `CatalogRef.XXX`, `DocumentObject.XXX`, `ValueTable`, `DynamicList`, `Type1 | Type2` (составной).

### Секции расширений

| Секция | Назначение |
|--------|-----------|
| `formEvents` | События уровня формы с `callType` (Before/After/Override) |
| `elementEvents` | События на существующих элементах заимствованной формы |
| `callType` на `commands` | callType на Action команды |
| `callType` на `on` | callType на событиях новых элементов (объектный формат) |

Все extension-секции опциональны — без них навык работает как с обычными формами.

## Workflow

1. `/form-info` — посмотреть текущую структуру формы
2. Создать JSON с описанием правок
3. `/form-edit` — применить; в выводе — что куда добавлено, перенесено и изменено
4. `/form-validate` — проверить корректность
