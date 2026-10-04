# Тонкая компоновка

Сверх основной геометрии (`width`, `height`, `horizontalStretch`, `verticalStretch`, `autoMaxWidth` — на главной странице). Интервалы и ширина колонок внутри группы — `references/groups-pages.md`. Все ключи необязательны.

## Выравнивание

| Ключ | Значения | Что выравнивает |
|------|----------|-----------------|
| `groupHorizontalAlign` | `Left` / `Center` / `Right` | Сам элемент в отведённом ему месте группы |
| `groupVerticalAlign` | `Top` / `Center` / `Bottom` | То же по вертикали |
| `horizontalAlign` | `Left` / `Center` / `Right` | Текст или значение внутри элемента |
| `verticalAlign` | `Top` / `Center` / `Bottom` | То же по вертикали |

```json
{ "button": "ОК", "command": "ОК", "groupHorizontalAlign": "Right" }
{ "input": "Сумма", "path": "Объект.Сумма", "horizontalAlign": "Right" }
```

## Предел размера

| Ключ | Значения | Назначение |
|------|----------|-----------|
| `maxWidth` / `maxHeight` | число | Жёсткий предел |
| `autoMaxWidth` / `autoMaxHeight` | `false` | Снять автоматический предел (поле тянется без ограничения) |
| `titleHeight` | число | Высота заголовка |

```json
{ "input": "Поиск", "path": "СтрокаПоиска", "horizontalStretch": true, "maxWidth": 60 }
```

## Ввод и фокус

| Ключ | Значения | Назначение |
|------|----------|-----------|
| `skipOnInput` | bool | Пропускать при переходе по Enter/Tab |
| `defaultItem` | `true` | Фокус при открытии формы |
| `shortcut` | `"Ctrl+F"` и т.п. | Сочетание клавиш для перехода к элементу |

## Узкие экраны (`displayImportance`)

`VeryHigh` / `High` / `Usual` / `Low` / `VeryLow` — при нехватке места менее важные элементы сворачиваются первыми.

```json
{ "input": "Комментарий", "path": "Объект.Комментарий", "displayImportance": "Low" }
```
