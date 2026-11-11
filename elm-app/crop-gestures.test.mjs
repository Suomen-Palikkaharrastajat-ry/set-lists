import assert from 'node:assert/strict'
import test from 'node:test'
import { createCropGestureTracker, installCropGestures, wheelZoomFactor } from './crop-gestures.mjs'

function frame(rect = { left: 0, top: 0, width: 400, height: 200 }) {
  const element = {
    getBoundingClientRect: () => rect,
    closest: () => element,
    focused: false,
    focus() {
      this.focused = true
    },
  }
  return element
}

test('wheel zoom goes in when scrolling up and out when scrolling down, and is bounded per event', () => {
  assert.equal(wheelZoomFactor(0), 1)
  assert.ok(wheelZoomFactor(-100) > 1)
  assert.ok(wheelZoomFactor(100) < 1)
  assert.equal(wheelZoomFactor(-1e6), 2)
  assert.equal(wheelZoomFactor(1e6), 0.5)
  assert.equal(wheelZoomFactor(-3, 1), wheelZoomFactor(-48, 0))
})

test('one pointer dragged across the frame pans by its movement as a share of the frame size', () => {
  const tracker = createCropGestureTracker()
  const surface = frame()
  tracker.down(1, surface, { x: 50, y: 50 })
  assert.deepEqual(tracker.move(1, { x: 70, y: 40 }), [
    { kind: 'pan', dx: 20 / 400, dy: -10 / 200, factor: 1, x: 0, y: 0 },
  ])
  assert.deepEqual(tracker.move(1, { x: 70, y: 40 }), [
    { kind: 'pan', dx: 0, dy: 0, factor: 1, x: 0, y: 0 },
  ])
})

test('two pointers pinching apart zoom by their distance ratio around their midpoint and follow the midpoint', () => {
  const tracker = createCropGestureTracker()
  const surface = frame()
  tracker.down(1, surface, { x: 100, y: 100 })
  tracker.down(2, surface, { x: 200, y: 100 })
  assert.deepEqual(tracker.move(2, { x: 300, y: 100 }), [
    { kind: 'pan', dx: 50 / 400, dy: 0, factor: 1, x: 0, y: 0 },
    { kind: 'zoom', dx: 0, dy: 0, factor: 2, x: 0.5, y: 0.5 },
  ])
})

test('after one pointer lifts, the remaining pointer pans from where it last was', () => {
  const tracker = createCropGestureTracker()
  const surface = frame()
  tracker.down(1, surface, { x: 100, y: 100 })
  tracker.down(2, surface, { x: 200, y: 100 })
  tracker.move(2, { x: 300, y: 100 })
  tracker.up(2)
  assert.deepEqual(tracker.move(1, { x: 90, y: 100 }), [
    { kind: 'pan', dx: -10 / 400, dy: 0, factor: 1, x: 0, y: 0 },
  ])
})

test('released or unknown pointers, extra pointers, and degenerate frames produce no gestures', () => {
  const tracker = createCropGestureTracker()
  const surface = frame()
  assert.deepEqual(tracker.move(9, { x: 1, y: 1 }), [])
  tracker.down(1, surface, { x: 0, y: 0 })
  tracker.down(2, surface, { x: 10, y: 0 })
  tracker.down(3, surface, { x: 20, y: 0 })
  assert.deepEqual(tracker.move(3, { x: 30, y: 0 }), [])
  tracker.up(1)
  tracker.up(2)
  assert.deepEqual(tracker.move(1, { x: 5, y: 5 }), [])

  const collapsed = createCropGestureTracker()
  collapsed.down(1, frame({ left: 0, top: 0, width: 0, height: 0 }), { x: 0, y: 0 })
  assert.deepEqual(collapsed.move(1, { x: 5, y: 5 }), [])
  assert.deepEqual(collapsed.wheel(frame({ left: 0, top: 0, width: 0, height: 0 }), { x: 1, y: 1 }, -10, 0), [])
})

test('a wheel over the crop frame reports zoom at the pointer without modifiers', () => {
  const tracker = createCropGestureTracker()
  const surface = frame()
  assert.deepEqual(tracker.wheel(surface, { x: 100, y: 50 }, -100, 0), [
    { kind: 'zoom', dx: 0, dy: 0, factor: wheelZoomFactor(-100, 0), x: 0.25, y: 0.25 },
  ])
})

class FakeEvent extends Event {
  constructor(type, properties = {}) {
    super(type, { cancelable: true })
    Object.assign(this, properties)
  }
}

function dispatch(root, type, target, properties = {}) {
  const event = new FakeEvent(type, { pointerType: 'touch', button: 0, buttons: 1, ...properties })
  Object.defineProperty(event, 'target', { value: target })
  root.dispatchEvent(event)
  return event
}

test('installed listeners forward gestures from crop frames only, and stop after disposal', () => {
  const root = new EventTarget()
  const sent = []
  const surface = frame()
  const outside = { closest: () => null, focus() {} }
  const dispose = installCropGestures(root, (message) => sent.push(message))

  const down = dispatch(root, 'pointerdown', surface, { pointerId: 1, clientX: 50, clientY: 50 })
  assert.equal(down.defaultPrevented, true)
  assert.equal(surface.focused, true)
  dispatch(root, 'pointermove', surface, { pointerId: 1, clientX: 90, clientY: 50 })
  assert.deepEqual(sent, [{ kind: 'pan', dx: 40 / 400, dy: 0, factor: 1, x: 0, y: 0 }])

  dispatch(root, 'pointerdown', outside, { pointerId: 2, clientX: 0, clientY: 0 })
  dispatch(root, 'pointermove', outside, { pointerId: 2, clientX: 40, clientY: 40 })
  assert.equal(sent.length, 1)

  dispatch(root, 'pointerup', surface, { pointerId: 1 })
  dispatch(root, 'pointermove', surface, { pointerId: 1, clientX: 120, clientY: 50 })
  assert.equal(sent.length, 1)

  const wheel = dispatch(root, 'wheel', surface, { deltaY: -100, deltaMode: 0, ctrlKey: false, metaKey: false, clientX: 100, clientY: 50 })
  assert.equal(wheel.defaultPrevented, true)
  assert.equal(sent.at(-1).kind, 'zoom')

  dispose()
  dispatch(root, 'pointerdown', surface, { pointerId: 3, clientX: 0, clientY: 0 })
  dispatch(root, 'pointermove', surface, { pointerId: 3, clientX: 10, clientY: 0 })
  assert.equal(sent.at(-1).kind, 'zoom')
  assert.equal(sent.length, 2)
})

test('a mouse pointer that lost its button is released without panning', () => {
  const root = new EventTarget()
  const sent = []
  const surface = frame()
  installCropGestures(root, (message) => sent.push(message))
  dispatch(root, 'pointerdown', surface, { pointerId: 1, pointerType: 'mouse', clientX: 10, clientY: 10 })
  dispatch(root, 'pointermove', surface, { pointerId: 1, pointerType: 'mouse', buttons: 0, clientX: 80, clientY: 10 })
  dispatch(root, 'pointermove', surface, { pointerId: 1, pointerType: 'mouse', buttons: 1, clientX: 90, clientY: 10 })
  assert.deepEqual(sent, [])
})
