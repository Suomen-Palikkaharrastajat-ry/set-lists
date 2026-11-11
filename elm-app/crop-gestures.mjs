const CROP_FRAME_SELECTOR = '[data-crop-frame]'
const WHEEL_PIXELS_PER_LINE = 16
const WHEEL_PIXELS_PER_PAGE = 400
const WHEEL_ZOOM_SENSITIVITY = 0.002
const MAX_STEP_FACTOR = 2

export function wheelZoomFactor(deltaY, deltaMode = 0) {
  const pixels = deltaMode === 2
    ? deltaY * WHEEL_PIXELS_PER_PAGE
    : deltaMode === 1
      ? deltaY * WHEEL_PIXELS_PER_LINE
      : deltaY
  const factor = Math.exp(-pixels * WHEEL_ZOOM_SENSITIVITY)
  return Math.min(MAX_STEP_FACTOR, Math.max(1 / MAX_STEP_FACTOR, factor))
}

function pan(dx, dy) {
  return { kind: 'pan', dx, dy, factor: 1, x: 0, y: 0 }
}

function zoom(factor, x, y) {
  return { kind: 'zoom', dx: 0, dy: 0, factor, x, y }
}

function midpoint(a, b) {
  return { x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 }
}

function distance(a, b) {
  return Math.hypot(a.x - b.x, a.y - b.y)
}

// Pure gesture state machine. Points are client coordinates; the reported
// movements are fractions of the frame's size, so the Elm side does not need
// to know the rendered size.
export function createCropGestureTracker() {
  const pointers = new Map()
  let pinch = null

  function frameSize(frame) {
    const rect = frame.getBoundingClientRect()
    return rect.width > 0 && rect.height > 0 ? rect : null
  }

  function fractionOf(rect, point) {
    return { x: (point.x - rect.left) / rect.width, y: (point.y - rect.top) / rect.height }
  }

  function startPinch() {
    const [first, second] = [...pointers.values()]
    if (first.frame !== second.frame) return null
    return {
      frame: first.frame,
      mid: midpoint(first.point, second.point),
      distance: distance(first.point, second.point),
    }
  }

  return {
    down(id, frame, point) {
      if (pointers.has(id) || pointers.size >= 2) return
      pointers.set(id, { frame, point })
      pinch = pointers.size === 2 ? startPinch() : null
    },

    move(id, point) {
      const pointer = pointers.get(id)
      if (!pointer) return []
      const previous = pointer.point
      pointer.point = point

      const rect = frameSize(pointer.frame)
      if (!rect) return []

      if (pointers.size === 1) {
        return [pan((point.x - previous.x) / rect.width, (point.y - previous.y) / rect.height)]
      }

      if (!pinch || pinch.frame !== pointer.frame) return []
      const [first, second] = [...pointers.values()]
      const mid = midpoint(first.point, second.point)
      const dist = distance(first.point, second.point)
      const previousPinch = pinch
      pinch = { frame: pointer.frame, mid, distance: dist }

      const messages = [
        pan((mid.x - previousPinch.mid.x) / rect.width, (mid.y - previousPinch.mid.y) / rect.height),
      ]
      if (previousPinch.distance > 0 && dist > 0) {
        const at = fractionOf(rect, mid)
        messages.push(zoom(dist / previousPinch.distance, at.x, at.y))
      }
      return messages
    },

    up(id) {
      pointers.delete(id)
      if (pointers.size < 2) pinch = null
    },

    wheel(frame, point, deltaY, deltaMode) {
      const rect = frameSize(frame)
      if (!rect) return []
      const at = fractionOf(rect, point)
      return [zoom(wheelZoomFactor(deltaY, deltaMode), at.x, at.y)]
    },
  }
}

// Wires pointer, touch, and wheel gestures on `[data-crop-frame]` elements under `root`.
// Listeners are removed by calling the returned function.
export function installCropGestures(root, send) {
  const tracker = createCropGestureTracker()
  const controller = new AbortController()
  const { signal } = controller

  const emit = (messages) => {
    for (const message of messages) send(message)
  }
  const frameOf = (target) => target?.closest?.(CROP_FRAME_SELECTOR) ?? null
  const pointOf = (event) => ({ x: event.clientX, y: event.clientY })

  root.addEventListener('pointerdown', (event) => {
    const frame = frameOf(event.target)
    if (!frame || (event.pointerType === 'mouse' && event.button !== 0)) return
    event.preventDefault()
    frame.focus?.({ preventScroll: true })
    tracker.down(event.pointerId, frame, pointOf(event))
  }, { signal })

  root.addEventListener('pointermove', (event) => {
    if (event.pointerType === 'mouse' && event.buttons === 0) {
      tracker.up(event.pointerId)
      return
    }
    emit(tracker.move(event.pointerId, pointOf(event)))
  }, { signal })

  const release = (event) => tracker.up(event.pointerId)
  root.addEventListener('pointerup', release, { signal })
  root.addEventListener('pointercancel', release, { signal })

  root.addEventListener('wheel', (event) => {
    const frame = frameOf(event.target)
    if (!frame) return
    event.preventDefault()
    emit(tracker.wheel(frame, pointOf(event), event.deltaY, event.deltaMode))
  }, { signal, passive: false })

  return () => controller.abort()
}
