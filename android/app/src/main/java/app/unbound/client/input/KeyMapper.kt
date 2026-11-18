package app.unbound.client.input

import android.view.KeyEvent
import app.unbound.client.net.Modifier

/**
 * Android key codes → macOS virtual key codes (ANSI layout, from HIToolbox/Events.h).
 * Physical-key mapping: the Mac applies its own keyboard layout, so shortcuts like
 * Cmd+C work regardless of the character the tablet would have produced.
 */
object KeyMapper {
    private val map: Map<Int, Int> = buildMap {
        val letters = mapOf(
            'A' to 0x00, 'S' to 0x01, 'D' to 0x02, 'F' to 0x03, 'H' to 0x04, 'G' to 0x05, 'Z' to 0x06,
            'X' to 0x07, 'C' to 0x08, 'V' to 0x09, 'B' to 0x0B, 'Q' to 0x0C, 'W' to 0x0D, 'E' to 0x0E,
            'R' to 0x0F, 'Y' to 0x10, 'T' to 0x11, 'O' to 0x1F, 'U' to 0x20, 'I' to 0x22, 'P' to 0x23,
            'L' to 0x25, 'J' to 0x26, 'K' to 0x28, 'N' to 0x2D, 'M' to 0x2E,
        )
        for ((ch, mac) in letters) put(KeyEvent.KEYCODE_A + (ch - 'A'), mac)
        val digits = intArrayOf(0x1D, 0x12, 0x13, 0x14, 0x15, 0x17, 0x16, 0x1A, 0x1C, 0x19) // 0..9
        for (d in 0..9) put(KeyEvent.KEYCODE_0 + d, digits[d])

        put(KeyEvent.KEYCODE_ENTER, 0x24)
        put(KeyEvent.KEYCODE_NUMPAD_ENTER, 0x4C)
        put(KeyEvent.KEYCODE_TAB, 0x30)
        put(KeyEvent.KEYCODE_SPACE, 0x31)
        put(KeyEvent.KEYCODE_DEL, 0x33)          // Backspace
        put(KeyEvent.KEYCODE_FORWARD_DEL, 0x75)
        put(KeyEvent.KEYCODE_ESCAPE, 0x35)
        put(KeyEvent.KEYCODE_MINUS, 0x1B)
        put(KeyEvent.KEYCODE_EQUALS, 0x18)
        put(KeyEvent.KEYCODE_LEFT_BRACKET, 0x21)
        put(KeyEvent.KEYCODE_RIGHT_BRACKET, 0x1E)
        put(KeyEvent.KEYCODE_BACKSLASH, 0x2A)
        put(KeyEvent.KEYCODE_SEMICOLON, 0x29)
        put(KeyEvent.KEYCODE_APOSTROPHE, 0x27)
        put(KeyEvent.KEYCODE_GRAVE, 0x32)
        put(KeyEvent.KEYCODE_COMMA, 0x2B)
        put(KeyEvent.KEYCODE_PERIOD, 0x2F)
        put(KeyEvent.KEYCODE_SLASH, 0x2C)
        put(KeyEvent.KEYCODE_DPAD_LEFT, 0x7B)
        put(KeyEvent.KEYCODE_DPAD_RIGHT, 0x7C)
        put(KeyEvent.KEYCODE_DPAD_DOWN, 0x7D)
        put(KeyEvent.KEYCODE_DPAD_UP, 0x7E)
        put(KeyEvent.KEYCODE_MOVE_HOME, 0x73)
        put(KeyEvent.KEYCODE_MOVE_END, 0x77)
        put(KeyEvent.KEYCODE_PAGE_UP, 0x74)
        put(KeyEvent.KEYCODE_PAGE_DOWN, 0x79)
        val fkeys = intArrayOf(0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D, 0x67, 0x6F)
        for (i in 0 until 12) put(KeyEvent.KEYCODE_F1 + i, fkeys[i])
        // Modifier keys themselves (so press-and-hold works in apps that watch flagsChanged)
        put(KeyEvent.KEYCODE_SHIFT_LEFT, 0x38)
        put(KeyEvent.KEYCODE_SHIFT_RIGHT, 0x3C)
        put(KeyEvent.KEYCODE_CTRL_LEFT, 0x3B)
        put(KeyEvent.KEYCODE_CTRL_RIGHT, 0x3E)
        put(KeyEvent.KEYCODE_ALT_LEFT, 0x3A)
        put(KeyEvent.KEYCODE_ALT_RIGHT, 0x3D)
        put(KeyEvent.KEYCODE_META_LEFT, 0x37)
        put(KeyEvent.KEYCODE_META_RIGHT, 0x36)
        put(KeyEvent.KEYCODE_CAPS_LOCK, 0x39)
    }

    fun macKeyCode(androidKeyCode: Int): Int? = map[androidKeyCode]

    /** Meta (Windows/Search key on most keyboards) acts as Command. */
    fun modifiers(e: KeyEvent): Int {
        var m = 0
        if (e.isShiftPressed) m = m or Modifier.SHIFT
        if (e.isCtrlPressed) m = m or Modifier.CONTROL
        if (e.isAltPressed) m = m or Modifier.OPTION
        if (e.isMetaPressed) m = m or Modifier.COMMAND
        if (e.isCapsLockOn) m = m or Modifier.CAPS_LOCK
        return m
    }
}
