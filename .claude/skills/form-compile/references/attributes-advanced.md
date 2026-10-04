# Реквизиты и параметры: сохранение, проверка заполнения, опции

Основное о реквизитах (`name`, `type`, `main`, `title`, `columns`, `savedData`) — на главной странице. Свойства команд — `references/buttons-commands.md`, доступ по ролям — `references/roles-access.md`. Все ключи необязательны.

## Реквизит

| Ключ | Значения | Назначение |
|------|----------|-----------|
| `fillCheck` | `true` | Проверять заполнение (ошибка, если пусто) |
| `save` | `true` / строка / массив | Запоминать значение в пользовательских настройках. Массив — под-поля: `["Период", "StartDate", "EndDate"]`. Работает, если у формы `saveDataInSettings: "UseList"` (`references/form-properties.md`) |
| `functionalOptions` | массив имён | Реквизит доступен только при включённых функциональных опциях |
| `valueType` | тип | Тип элементов у реквизита `ValueList`, напр. `"CatalogRef.Контрагенты"` |
| `useAlways` | массив полей | Поля, которые читаются всегда, даже без вывода на форму |
| `additionalColumns` | `[{ table, columns }]` | Доп. колонки табличной части основного реквизита: `{ "table": "Объект.Товары", "columns": [ … ] }` |

У колонок `ValueTable`/`ValueTree` (`columns[*]`) — те же `title`, `fillCheck`, `functionalOptions`.

```json
{ "name": "Период", "type": "StandardPeriod", "save": ["Период", "StartDate", "EndDate", "Variant"] }
{ "name": "Склад", "type": "CatalogRef.Склады", "fillCheck": true, "functionalOptions": ["ИспользоватьСклады"] }
{ "name": "Отобранные", "type": "ValueList", "valueType": "CatalogRef.Номенклатура" }
```

## Параметр формы

| Ключ | Значения | Назначение |
|------|----------|-----------|
| `key` | `true` | Ключевой параметр (форма с разными значениями — разные окна) |
