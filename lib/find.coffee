{$} = require 'atom-space-pen-views'
{CompositeDisposable, TextBuffer} = require 'atom'

SelectNext = require './select-next'
{History, HistoryCycler} = require './history'
FindOptions = require './find-options'
BufferSearch = require './buffer-search'
FindView = require './find-view'
ProjectFindView = require './project-find-view'
ResultsModel = require './project/results-model'
ResultsPaneView = require './project/results-pane'

module.exports =
  config:
    focusEditorAfterSearch:
      type: 'boolean'
      default: false
      description: 'Focus the editor and select the next match when a file search is executed. If no matches are found, the editor will not be focused.'
    openProjectFindResultsInRightPane:
      type: 'boolean'
      default: false
      description: 'When a project-wide search is executed, open the results in a split pane instead of a tab in the same pane.'
    closeFindPanelAfterSearch:
      type: 'boolean'
      default: false
      title: 'Close Project Find Panel After Search'
      description: 'Close the find panel after executing a project-wide search.'
    scrollToResultOnLiveSearch:
      type: 'boolean'
      default: false
      title: 'Scroll To Result On Live-Search (incremental find in buffer)'
      description: 'Scroll to and select the closest match while typing in the buffer find box.'
    liveSearchMinimumCharacters:
      type: 'integer'
      default: 3
      minimum: 0
      description: 'The minimum number of characters which need to be typed into the buffer find box before search starts matching and highlighting matches as you type.'

  activate: ({findOptions, findHistory, replaceHistory, pathsHistory}={}) ->
    atom.workspace.addOpener (filePath) ->
      new ResultsPaneView() if filePath is ResultsPaneView.URI

    @subscriptions = new CompositeDisposable
    @findHistory = new History(findHistory)
    @replaceHistory = new History(replaceHistory)
    @pathsHistory = new History(pathsHistory)

    @findOptions = new FindOptions(findOptions)
    @findModel = new BufferSearch(@findOptions)
    @resultsModel = new ResultsModel(@findOptions)

    @subscriptions.add atom.workspace.observeActivePaneItem (paneItem) =>
      if paneItem?.getBuffer?()
        @findModel.setEditor(paneItem)
      else
        @findModel.setEditor(null)

    @subscriptions.add atom.commands.add '.find-and-replace, .project-find', 'window:focus-next-pane', ->
      atom.views.getView(atom.workspace).focus()

    @subscriptions.add atom.commands.add 'atom-workspace', 'project-find:show', =>
      @createViews()
      @findPanel.hide()
      @projectFindPanel.show()
      @projectFindView.focusFindElement()

    @subscriptions.add atom.commands.add 'atom-workspace', 'project-find:toggle', =>
      @createViews()
      @findPanel.hide()

      if @projectFindPanel.isVisible()
        @projectFindPanel.hide()
      else
        @projectFindPanel.show()

    @subscriptions.add atom.commands.add 'atom-workspace', 'project-find:show-in-current-directory', ({target}) =>
      @createViews()
      @findPanel.hide()
      @projectFindPanel.show()
      @projectFindView.findInCurrentlySelectedDirectory(target)

    @subscriptions.add atom.commands.add 'atom-workspace', 'find-and-replace:use-selection-as-find-pattern', =>
      return if @projectFindPanel?.isVisible() or @findPanel?.isVisible()

      @createViews()
      @projectFindPanel.hide()
      @findPanel.show()
      @findView.focusFindEditor()

    @subscriptions.add atom.commands.add 'atom-workspace', 'find-and-replace:toggle', =>
      @createViews()
      @projectFindPanel.hide()

      if @findPanel.isVisible()
        @findPanel.hide()
      else
        @findPanel.show()
        @findView.focusFindEditor()

    @subscriptions.add atom.commands.add 'atom-workspace', 'find-and-replace:show', =>
      @createViews()
      @projectFindPanel.hide()
      @findPanel.show()
      @findView.focusFindEditor()

    @subscriptions.add atom.commands.add 'atom-workspace', 'find-and-replace:show-replace', =>
      @createViews()
      @projectFindPanel?.hide()
      @findPanel.show()
      @findView.focusReplaceEditor()

    # Handling cancel in the workspace + code editors
    handleEditorCancel = ({target}) =>
      isMiniEditor = target.tagName is 'ATOM-TEXT-EDITOR' and target.hasAttribute('mini')
      unless isMiniEditor
        @findPanel?.hide()
        @projectFindPanel?.hide()

    @subscriptions.add atom.commands.add 'atom-workspace',
      'core:cancel': handleEditorCancel
      'core:close': handleEditorCancel

    selectNextObjectForEditorElement = (editorElement) =>
      @selectNextObjects ?= new WeakMap()
      editor = editorElement.getModel()
      selectNext = @selectNextObjects.get(editor)
      unless selectNext?
        selectNext = new SelectNext(editor)
        @selectNextObjects.set(editor, selectNext)
      selectNext

    atom.commands.add '.editor:not(.mini)',
      'find-and-replace:select-next': (event) ->
        selectNextObjectForEditorElement(this).findAndSelectNext()
      'find-and-replace:select-all': (event) ->
        selectNextObjectForEditorElement(this).findAndSelectAll()
      'find-and-replace:select-undo': (event) ->
        selectNextObjectForEditorElement(this).undoLastSelection()
      'find-and-replace:select-skip': (event) ->
        selectNextObjectForEditorElement(this).skipCurrentSelection()

  provideService: ->
    resultsMarkerLayerForTextEditor: @findModel.resultsMarkerLayerForTextEditor.bind(@findModel)

  createViews: ->
    return if @findView?

    findBuffer = new TextBuffer
    replaceBuffer = new TextBuffer
    pathsBuffer = new TextBuffer

    findHistoryCycler = new HistoryCycler(findBuffer, @findHistory)
    replaceHistoryCycler = new HistoryCycler(replaceBuffer, @replaceHistory)
    pathsHistoryCycler = new HistoryCycler(pathsBuffer, @pathsHistory)

    options = {findBuffer, replaceBuffer, pathsBuffer, findHistoryCycler, replaceHistoryCycler, pathsHistoryCycler}

    @findView = new FindView(@findModel, options)
    @projectFindView = new ProjectFindView(@resultsModel, options)

    @findPanel = atom.workspace.addBottomPanel(item: @findView, visible: false, className: 'tool-panel panel-bottom')
    @projectFindPanel = atom.workspace.addBottomPanel(item: @projectFindView, visible: false, className: 'tool-panel panel-bottom')

    @findView.setPanel(@findPanel)
    @projectFindView.setPanel(@projectFindPanel)

    # HACK: Soooo, we need to get the model to the pane view whenever it is
    # created. Creation could come from the opener below, or, more problematic,
    # from a deserialize call when splitting panes. For now, all pane views will
    # use this same model. This needs to be improved! I dont know the best way
    # to deal with this:
    # 1. How should serialization work in the case of a shared model.
    # 2. Or maybe we create the model each time a new pane is created? Then
    #    ProjectFindView needs to know about each model so it can invoke a search.
    #    And on each new model, it will run the search again.
    #
    # See https://github.com/atom/find-and-replace/issues/63
    ResultsPaneView.model = @resultsModel

  deactivate: ->
    @findPanel?.destroy()
    @findPanel = null
    @findView?.destroy()
    @findView = null
    @findModel?.destroy()
    @findModel = null

    @projectFindPanel?.destroy()
    @projectFindPanel = null
    @projectFindView?.destroy()
    @projectFindView = null

    ResultsPaneView.model = null
    @resultsModel = null

    @subscriptions?.dispose()
    @subscriptions = null

  serialize: ->
    findOptions: @findOptions.serialize()
    findHistory: @findHistory.serialize()
    replaceHistory: @replaceHistory.serialize()
    pathsHistory: @pathsHistory.serialize()
