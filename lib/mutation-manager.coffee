{Point, CompositeDisposable} = require 'atom'
swrap = require './selection-wrapper'

# keep mutation snapshot necessary for Operator processing.
# mutation stored by each Selection have following field
#  marker:
#    marker to track mutation. marker is created when `setCheckPoint`
#  createdAt:
#    'string' representing when marker was created.
#  checkPoint: {}
#    key is ['will-select', 'did-select', 'will-mutate', 'did-mutate']
#    key is checkpoint, value is bufferRange for marker at that checkpoint
#  selection:
#    Selection beeing tracked
module.exports =
class MutationManager
  constructor: (@vimState) ->
    {@editor} = @vimState

    @disposables = new CompositeDisposable
    @disposables.add @vimState.onDidDestroy(@destroy.bind(this))

    @markerLayer = @editor.addMarkerLayer()
    @mutationsBySelection = new Map

  destroy: ->
    @reset()
    {@mutationsBySelection, @editor, @vimState} = {}

  init: (@options) ->
    @reset()

  reset: ->
    marker.destroy() for marker in @markerLayer.getMarkers()
    @mutationsBySelection.clear()

  saveInitialPointForSelection: (selection) ->
    if @vimState.isMode('visual')
      point = swrap(selection).getBufferPositionFor('head', fromProperty: true, allowFallback: true)
    else
      point = swrap(selection).getBufferPositionFor('head') unless @options.isSelect
    if @options.useMarker
      point = @markerLayer.markBufferPosition(point, invalidate: 'never')
    point

  getInitialPointForSelection: (selection) ->
    @mutationsBySelection.get(selection)?.initialPoint

  setCheckPoint: (checkPoint) ->
    for selection in @editor.getSelections()
      unless @mutationsBySelection.has(selection)
        createdAt = checkPoint
        initialPoint = @saveInitialPointForSelection(selection)
        options = {selection, initialPoint, createdAt, @markerLayer}
        @mutationsBySelection.set(selection, new Mutation(options))
      mutation = @mutationsBySelection.get(selection)
      mutation.update(checkPoint)

  getMutationForSelection: (selection) ->
    @mutationsBySelection.get(selection)

  getMarkerBufferRanges: ->
    ranges = []
    @mutationsBySelection.forEach (mutation, selection) ->
      if range = mutation.marker?.getBufferRange()
        ranges.push(range)
    ranges

  restoreInitialPositions: ->
    for selection in @editor.getSelections() when point = @getInitialPointForSelection(selection)
      selection.cursor.setBufferPosition(point)

  restoreCursorPositions: (options) ->
    {stay, strict, isBlockwise} = options
    if isBlockwise
      # [FIXME] why I need this direct manupilation?
      # Because there's bug that blockwise selecction is not addes to each
      # bsInstance.selection. Need investigation.
      points = []
      @mutationsBySelection.forEach (mutation, selection) ->
        points.push(mutation.checkPoint['will-select']?.start)
      points = points.sort (a, b) -> a.compare(b)
      points = points.filter (point) -> point?
      if @vimState.isMode('visual', 'blockwise')
        if point = points[0]
          @vimState.getLastBlockwiseSelection()?.setHeadBufferPosition(point)
      else
        if point = points[0]
          @editor.setCursorBufferPosition(point)
        else
          for selection in @editor.getSelections()
            selection.destroy() unless selection.isLastSelection()
    else
      for selection, i in @editor.getSelections()
        if mutation = @mutationsBySelection.get(selection)
          if strict and mutation.createdAt isnt 'will-select'
            selection.destroy()
            continue

          if point = mutation.getRestorePoint({stay})
            selection.cursor.setBufferPosition(point)
        else
          if strict
            selection.destroy()

# mutation information is created even if selection.isEmpty()
# So that we can filter selection by when it was created.
# e.g. some selection is created at 'will-select' checkpoint, others at 'did-select'
# This is important since when occurrence modifier is used, selection is created at target.select()
# In that case some selection have createdAt = `did-select`, and others is createdAt = `will-select`
class Mutation
  constructor: (options) ->
    {@selection, @initialPoint, @createdAt, @markerLayer} = options
    @checkPoint = {}
    @marker = null

  update: (checkPoint) ->
    # Current non-empty selection is prioritized over marker's range.
    # We ivalidate old marker to re-track from current selection.
    unless @selection.getBufferRange().isEmpty()
      @marker?.destroy()
      @marker = null

    @marker ?= @markerLayer.markBufferRange(@selection.getBufferRange(), invalidate: 'never')
    @checkPoint[checkPoint] = @marker.getBufferRange()

  getMutationEnd: ->
    range = @marker.getBufferRange()
    if range.isEmpty()
      range.end
    else
      point = range.end.translate([0, -1])
      @selection.editor.clipBufferPosition(point)

  getRestorePoint: (options={}) ->
    if options.stay
      if @initialPoint instanceof Point
        point = @initialPoint
      else
        point = @initialPoint.getHeadBufferPosition()

      Point.min(@getMutationEnd(), point)
    else
      @checkPoint['did-move']?.start ? @checkPoint['did-select']?.start
