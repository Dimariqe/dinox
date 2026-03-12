# Bug: Sichtbares Scrollen beim Öffnen von Chats

## Problem
Wenn ein Chat oder MUC mit vielen Nachrichten geöffnet wird, scrollt die Ansicht sichtbar vom ersten bis zum letzten Eintrag durch, statt direkt die neuesten Nachrichten anzuzeigen.

## Betroffene Datei
`main/src/ui/conversation_content_view/conversation_view.vala`

## Ursache

### 1. Batched Loading (Zeile 486–530)
`display_latest()` lädt 40 Nachrichten in Mini-Batches mit 2ms Zeitbudget (`DISPLAY_LATEST_BATCH_BUDGET_US = 2000`). Nach jedem Batch wird die Kontrolle an die GTK-Hauptschleife zurückgegeben (`Idle.add` → `return true`), wodurch GTK zwischen den Batches **rendert**.

### 2. `on_upper_notify()` scrollt bei jedem Batch (Zeile 721–740)
Jeder Batch fügt Widgets ein → `upper` Property ändert sich → `on_upper_notify()` feuert → setzt `vadjustment.value = upper - page_size` → sichtbarer Scroll nach unten.

### 3. `bulk_inserting_latest` wird nicht zum Unterdrücken genutzt
Das Flag existiert (Zeile 68), wird aber in `on_upper_notify()` **nicht** abgefragt. Es wird nur an `ConversationItemSkeleton` weitergereicht.

### 4. `at_current_content` bleibt während des Ladens `true`
`clear()` setzt `at_current_content` **nicht** zurück. Es bleibt `true` vom vorherigen Chat und wird erst am Ende von `display_latest()` (Zeile 565) wieder explizit auf `true` gesetzt. Dadurch ist `at_current_content` während des gesamten Ladevorgangs durchgehend `true` → `on_upper_notify()` scrollt bei **jedem** Batch nach unten.

In `on_upper_notify()` (Zeile 722) ist die Bedingung:
- Beim ersten Aufruf: `was_upper == null` (durch `clear()`) → **immer true**
- Bei Folge-Aufrufen: `value > was_upper - was_page_size - 1` → **true**, weil der vorherige Scroll `value` bereits ans Ende gesetzt hat

Kombiniert mit `at_current_content == true` wird der Scroll-Branch bei jedem Batch ausgeführt.

## Ablauf (aktuell)
```
clear() → was_upper = null, at_current_content bleibt true
Batch 1: ~5 Nachrichten → GTK rendert → on_upper_notify() → was_upper==null → scroll ↓
Batch 2: ~5 Nachrichten → GTK rendert → on_upper_notify() → value ≈ upper → scroll ↓
...
Batch N: Letzte Nachrichten → finaler Scroll (Zeile 556–562)
```

## Lösung
`on_upper_notify()` während des Bulk-Ladens unterdrücken:

```vala
private void on_upper_notify() {
    // Während des initialen Ladens NICHT scrollen - erst am Ende
    if (bulk_inserting_latest) {
        was_upper = scrolled.vadjustment.upper;
        was_page_size = scrolled.vadjustment.page_size;
        return;
    }
    
    if (was_upper == null || scrolled.vadjustment.value > was_upper - was_page_size - 1) {
        if (at_current_content) {
            Idle.add(() => {
                scrolled.vadjustment.value = scrolled.vadjustment.upper - scrolled.vadjustment.page_size;
                return false;
            });
        }
    } else if (scrolled.vadjustment.value < scrolled.vadjustment.upper - scrolled.vadjustment.page_size - 1) {
        scrolled.vadjustment.value = scrolled.vadjustment.upper - was_upper + scrolled.vadjustment.value;
    }
    was_upper = scrolled.vadjustment.upper;
    was_page_size = scrolled.vadjustment.page_size;
    was_value = scrolled.vadjustment.value;
    reloading_mutex.trylock();
    reloading_mutex.unlock();
}
```

Der finale Scroll zum Ende passiert bereits in `display_latest()` (Zeile 556–562) nach Abschluss aller Batches.

## Status
- [x] Implementiert
