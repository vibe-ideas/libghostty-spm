#if canImport(AppKit) && !canImport(UIKit)
    import AppKit
    import GhosttyKit

    extension AppTerminalView {
        /// A bounded text envelope around the selection and insertion cursor.
        /// The three header lines are Unicode-scalar offsets: cursor, selection
        /// start, and selection length. The remaining text is the envelope.
        /// Call only at the live viewport; hard line boundaries return nil.
        public func readSelectionEditContext() -> String? {
            guard let raw = surface?.rawValue,
                  !ghostty_surface_mouse_captured(raw) else { return nil }
            let size = ghostty_surface_size(raw)
            let columns = Int(size.columns)
            let rows = Int(size.rows)
            guard columns > 0, rows > 0, size.cell_height_px > 0 else { return nil }

            func read(_ first: Int, _ last: Int) -> (text: String, start: Int, length: Int, x: Double, y: Double)? {
                guard first >= 0, first <= last, last < rows * columns else { return nil }
                func point(_ index: Int) -> ghostty_point_s {
                    ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_EXACT,
                                    x: UInt32(index % columns), y: UInt32(index / columns))
                }
                var out = ghostty_text_s()
                guard ghostty_surface_read_text(raw, ghostty_selection_s(
                    top_left: point(first), bottom_right: point(last), rectangle: false
                ), &out) else { return nil }
                defer { ghostty_surface_free_text(raw, &out) }
                let text = out.text.map { String(decoding: UnsafeRawBufferPointer(start: $0, count: Int(out.text_len)), as: UTF8.self) } ?? ""
                return (text, Int(out.offset_start), Int(out.offset_len), out.tl_px_x, out.tl_px_y)
            }

            var selected = ghostty_text_s()
            guard ghostty_surface_read_selection(raw, &selected) else { return nil }
            defer { ghostty_surface_free_text(raw, &selected) }
            guard let bytes = selected.text, selected.text_len > 0, selected.text_len <= 1_048_576,
                  let origin = read(0, 0) else { return nil }
            let selectedText = String(decoding: UnsafeRawBufferPointer(start: bytes, count: Int(selected.text_len)), as: UTF8.self)
            let start = Int(selected.offset_start)
            let end = start + Int(selected.offset_len) + 1
            guard let check = read(start, end - 1), check.text == selectedText else { return nil }

            let ime = surface!.imePoint()
            let cellWidth = Double(size.cell_width_px) * ime.height / Double(size.cell_height_px)
            guard cellWidth > 0, ime.height > 0 else { return nil }
            let column = Int(floor((ime.x - origin.x) / cellWidth))
            let row = Int(floor((ime.y - origin.y) / ime.height))
            // The C API cannot distinguish a pending wrap from an insertion
            // before the last column. Refuse that ambiguous cursor position.
            guard column >= 0, column < columns - 1, row >= 0, row < rows else { return nil }
            let cursor = row * columns + column
            let first = min(cursor, start)
            let last = max(cursor, end)
            // Include the cursor cell in the boundary check: a range ending
            // just before column zero can otherwise omit a final hard newline.
            guard let boundary = read(first, max(cursor, end - 1))?.text,
                  !boundary.contains("\n") else { return nil }
            guard let envelope = read(first, last - 1)?.text,
                  !envelope.contains("\n"), !envelope.contains("\0") else { return nil }
            func prefix(to position: Int) -> String? {
                position == first ? "" : read(first, position - 1)?.text
            }
            guard let beforeCursor = prefix(to: cursor), let beforeSelection = prefix(to: start),
                  let afterSelection = end == last ? "" : read(end, last - 1)?.text,
                  envelope == beforeSelection + selectedText + afterSelection,
                  envelope.hasPrefix(beforeCursor) else { return nil }
            return "\(beforeCursor.unicodeScalars.count)\n\(beforeSelection.unicodeScalars.count)\n\(selectedText.unicodeScalars.count)\n\(envelope)"
        }
    }
#endif
