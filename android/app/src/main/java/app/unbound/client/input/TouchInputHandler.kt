package app.unbound.client.input

import android.os.Handler
import android.os.Looper
import android.view.InputDevice
import android.view.MotionEvent
import android.view.View
import android.view.ViewConfiguration
import app.unbound.client.net.Messages
import app.unbound.client.net.MouseButton
import app.unbound.client.net.PointerAction
import kotlin.math.hypot

/**
 * Maps touch / mouse / stylus on the video view to Mac pointer events.
 *
 * Finger gestures (direct-touch display semantics):
 *  - tap            → left click (double-tap → double click; the host tracks click count)
 *  - press + move   → left drag
 *  - long press     → right click
 *  - two fingers    → scroll
 *  - three-finger tap → [onThreeFingerTap] (toggles the stats overlay)
 * A mouse or stylus connected to the tablet is passed through as a mouse.
 */
class TouchInputHandler(
    private val view: View,
    private val videoWidth: () -> Int,
    private val send: (ByteArray) -> Unit,
    private val onThreeFingerTap: () -> Unit,
) : View.OnTouchListener, View.OnGenericMotionListener {

    private val touchSlop = ViewConfiguration.get(view.context).scaledTouchSlop.toFloat()
    private val longPressMs = ViewConfiguration.getLongPressTimeout().toLong()
    private val main = Handler(Looper.getMainLooper())

    private enum class Mode { IDLE, PENDING, DRAGGING, SCROLLING, CONSUMED }

    private var mode = Mode.IDLE
    private var startX = 0f
    private var startY = 0f
    private var lastCx = 0f
    private var lastCy = 0f
    private var maxPointers = 0
    private var mouseButtons = 0

    private val longPress = Runnable {
        if (mode == Mode.PENDING) {
            mode = Mode.CONSUMED
            pointer(PointerAction.DOWN, MouseButton.RIGHT, startX, startY)
            pointer(PointerAction.UP, MouseButton.RIGHT, startX, startY)
            view.performHapticFeedback(android.view.HapticFeedbackConstants.LONG_PRESS)
        }
    }

    override fun onTouch(v: View, e: MotionEvent): Boolean {
        if (e.isFromSource(InputDevice.SOURCE_MOUSE) || e.getToolType(0) == MotionEvent.TOOL_TYPE_MOUSE) {
            return handleMouse(e)
        }
        when (e.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                mode = Mode.PENDING
                maxPointers = 1
                startX = e.x; startY = e.y
                pointer(PointerAction.MOVE, MouseButton.LEFT, e.x, e.y) // put the cursor under the finger
                main.postDelayed(longPress, longPressMs)
            }
            MotionEvent.ACTION_POINTER_DOWN -> {
                maxPointers = maxOf(maxPointers, e.pointerCount)
                main.removeCallbacks(longPress)
                if (mode == Mode.DRAGGING) pointer(PointerAction.UP, MouseButton.LEFT, e.getX(0), e.getY(0))
                if (e.pointerCount == 2) {
                    mode = Mode.SCROLLING
                    lastCx = centroidX(e); lastCy = centroidY(e)
                    pointer(PointerAction.MOVE, MouseButton.LEFT, lastCx, lastCy)
                } else {
                    mode = Mode.CONSUMED
                }
            }
            MotionEvent.ACTION_MOVE -> when (mode) {
                Mode.PENDING -> if (hypot(e.x - startX, e.y - startY) > touchSlop) {
                    main.removeCallbacks(longPress)
                    mode = Mode.DRAGGING
                    pointer(PointerAction.DOWN, MouseButton.LEFT, startX, startY)
                    pointer(PointerAction.MOVE, MouseButton.LEFT, e.x, e.y)
                }
                Mode.DRAGGING -> pointer(PointerAction.MOVE, MouseButton.LEFT, e.x, e.y)
                Mode.SCROLLING -> if (e.pointerCount >= 2) {
                    val cx = centroidX(e); val cy = centroidY(e)
                    val scale = viewToVideoScale()
                    send(Messages.scroll((cx - lastCx) * scale, (cy - lastCy) * scale))
                    lastCx = cx; lastCy = cy
                }
                else -> {}
            }
            MotionEvent.ACTION_POINTER_UP -> {
                if (mode == Mode.SCROLLING) mode = Mode.CONSUMED
            }
            MotionEvent.ACTION_UP -> {
                main.removeCallbacks(longPress)
                when (mode) {
                    Mode.PENDING -> {
                        pointer(PointerAction.DOWN, MouseButton.LEFT, startX, startY)
                        pointer(PointerAction.UP, MouseButton.LEFT, startX, startY)
                    }
                    Mode.DRAGGING -> pointer(PointerAction.UP, MouseButton.LEFT, e.x, e.y)
                    else -> if (maxPointers == 3) onThreeFingerTap()
                }
                mode = Mode.IDLE
            }
            MotionEvent.ACTION_CANCEL -> {
                main.removeCallbacks(longPress)
                if (mode == Mode.DRAGGING) pointer(PointerAction.CANCEL, MouseButton.LEFT, e.x, e.y)
                mode = Mode.IDLE
            }
        }
        return true
    }

    /** Hover (mouse/stylus) and wheel events. */
    override fun onGenericMotion(v: View, e: MotionEvent): Boolean {
        when (e.actionMasked) {
            MotionEvent.ACTION_HOVER_MOVE, MotionEvent.ACTION_HOVER_ENTER ->
                pointer(PointerAction.MOVE, MouseButton.LEFT, e.x, e.y)
            MotionEvent.ACTION_SCROLL -> {
                val lines = 40f
                send(Messages.scroll(e.getAxisValue(MotionEvent.AXIS_HSCROLL) * -lines,
                    e.getAxisValue(MotionEvent.AXIS_VSCROLL) * lines))
            }
            else -> return false
        }
        return true
    }

    private fun handleMouse(e: MotionEvent): Boolean {
        val buttons = e.buttonState
        val changed = buttons xor mouseButtons
        if (changed and MotionEvent.BUTTON_PRIMARY != 0) {
            pointer(if (buttons and MotionEvent.BUTTON_PRIMARY != 0) PointerAction.DOWN else PointerAction.UP,
                MouseButton.LEFT, e.x, e.y)
        }
        if (changed and MotionEvent.BUTTON_SECONDARY != 0) {
            pointer(if (buttons and MotionEvent.BUTTON_SECONDARY != 0) PointerAction.DOWN else PointerAction.UP,
                MouseButton.RIGHT, e.x, e.y)
        }
        if (changed == 0 && e.actionMasked == MotionEvent.ACTION_MOVE) {
            pointer(PointerAction.MOVE, MouseButton.LEFT, e.x, e.y)
        }
        mouseButtons = buttons
        return true
    }

    private fun pointer(action: PointerAction, button: MouseButton, x: Float, y: Float) {
        val w = view.width.coerceAtLeast(1).toFloat()
        val h = view.height.coerceAtLeast(1).toFloat()
        send(Messages.pointer(action, button, (x / w).coerceIn(0f, 1f), (y / h).coerceIn(0f, 1f)))
    }

    private fun viewToVideoScale(): Float {
        val vw = videoWidth()
        return if (vw > 0 && view.width > 0) vw.toFloat() / view.width else 1f
    }

    private fun centroidX(e: MotionEvent) = (0 until e.pointerCount).map { e.getX(it) }.average().toFloat()
    private fun centroidY(e: MotionEvent) = (0 until e.pointerCount).map { e.getY(it) }.average().toFloat()
}
