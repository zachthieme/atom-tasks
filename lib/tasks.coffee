moment = require 'moment'
CSON = require atom.config.resourcePath + "/node_modules/season/lib/cson.js"
TaskGrammar = require './task-grammar'
Grammar = require atom.config.resourcePath + "/node_modules/first-mate/lib/grammar.js"

lpad = (value, padding) ->
  zeroes = "0"
  zeroes += "0" for i in [1..padding]
  (zeroes + value).slice(padding * -1)

mapSelectedItems = (editor, cb)->
  ranges = editor.getSelectedBufferRanges()
  coveredLines = []

  ranges.map (range)->
    coveredLines.push y for y in [range.start.row..range.end.row]

  lastProject = undefined

  coveredLines.map (row)->
    sp = [row,0]
    ep = [row,editor.lineLengthForBufferRow(row)]
    text = editor.getTextInBufferRange [sp, ep]

    for r in [row..0]
      tsp = [r, 0]
      tep = [r, editor.lineLengthForBufferRow(r)]
      checkLine = editor.getTextInBufferRange [tsp, tep]
      if checkLine.indexOf(':') is checkLine.length - 1
        lastProject = checkLine.replace(':', '')
        break

    cb text, lastProject, sp, ep

  {
    lines: coveredLines
    ranges: ranges
  }

marker = completeMarker = cancelledMarker = ''
projectRegex = /@project[ ]?\((.*?)\)/
doneRegex = /@done[ ]?(?:\((.*?)\))?/
cancelledRegex = /@cancelled[ ]?(?:\((.*?)\))?/


# CORE MODULE
module.exports =

  configDefaults:
    dateFormat: "YYYY-MM-DD hh:mm"
    baseMarker: '☐'
    completeMarker: '✔'
    cancelledMarker: '✘'

  activate: (state) ->


    marker = atom.config.get('tasks.baseMarker')
    completeMarker = atom.config.get('tasks.completeMarker')
    cancelledMarker = atom.config.get('tasks.cancelledMarker')

    atom.config.observe 'tasks.baseMarker', (val)=> marker = val; @updateGrammar()
    atom.config.observe 'tasks.completeMarker', (val)=> completeMarker = val; @updateGrammar()
    atom.config.observe 'tasks.cancelledMarker', (val)=> cancelledMarker = val; @updateGrammar()

    @updateGrammar()

    atom.workspaceView.command "tasks:add", => @newTask()
    atom.workspaceView.command "tasks:complete", => @completeTask()
    atom.workspaceView.command "tasks:archive", => @tasksArchive()
    atom.workspaceView.command "tasks:updateTimestamps", => @tasksUpdateTimestamp()
    atom.workspaceView.command "tasks:cancel", => @cancelTask()

    atom.workspaceView.eachEditorView (editorView) ->
      path = editorView.getEditor().getPath()
      if path.indexOf('.todo')>-1 or path.indexOf('.taskpaper')>-1
        editorView.addClass 'task-list'

  updateGrammar: ->
    clean = (str)->
      for pat in ['\\', '/', '[', ']', '*', '.', '+', '(', ')']
        str = str.replace pat, '\\' + pat
      str

    g = CSON.readFileSync __dirname + '/tasks.cson'
    rep = (prop)->
      str = prop
      str = str.replace '☐', clean marker
      str = str.replace '✔', clean completeMarker
      str = str.replace '✘', clean cancelledMarker
    mat = (ob)->
      res = []
      for pat in ob
        pat.begin = rep(pat.begin) if pat.begin
        pat.end = rep(pat.end) if pat.end
        pat.match = rep(pat.match) if pat.match
        if pat.patterns
          pat.patterns = mat pat.patterns
        res.push pat
      res

    g.patterns = mat g.patterns

    # first, clear existing grammar
    atom.syntax.removeGrammarForScopeName 'source.task'
    newG = new Grammar atom.syntax, g
    atom.syntax.addGrammar newG

    # Reload all todo grammars to match
    atom.workspaceView.eachEditorView (editorView) ->
      path = editorView.getEditor().getPath()
      if path.indexOf('.todo')>-1 or path.indexOf('.taskpaper')>-1
        editorView.editor.reloadGrammar()

  deactivate: ->

  serialize: ->

  newTask: ->
    editor = atom.workspace.getActiveEditor()
    editor.transact ->
      current_pos = editor.getCursorBufferPosition()
      prev_line = editor.lineForBufferRow(current_pos.row)
      indentLevel = prev_line.match(/^(\s+)/)?[0]
      targTab = Array(atom.config.get('editor.tabLength') + 1).join(' ')
      indentLevel = if not indentLevel then targTab else ''
      editor.insertNewlineBelow()
      # should have a minimum of one tab in
      editor.insertText indentLevel + atom.config.get('tasks.baseMarker') + ' '

  completeTask: ->
    editor = atom.workspace.getActiveEditor()

    editor.transact ->
      {lines, ranges} = mapSelectedItems editor, (line, lastProject, bufferStart, bufferEnd)->
        if not doneRegex.test line
          line = line.replace marker, completeMarker
          line += " @done(#{moment().format(atom.config.get('tasks.dateFormat'))})"
          line += " @project(#{lastProject})" if lastProject
        else
          line = line.replace completeMarker, marker
          line = line.replace doneRegex, ''
          line = line.replace projectRegex, ''
          line = line.trimRight()

        editor.setTextInBufferRange [bufferStart,bufferEnd], line
      editor.setSelectedBufferRanges ranges

  cancelTask: ->
    editor = atom.workspace.getActiveEditor()

    editor.transact ->
      {lines, ranges} = mapSelectedItems editor, (line, lastProject, bufferStart, bufferEnd)->
        if not cancelledRegex.test line
          line = line.replace marker, cancelledMarker
          line += " @cancelled(#{moment().format(atom.config.get('tasks.dateFormat'))})"
          line += " @project(#{lastProject})" if lastProject
        else
          line = line.replace cancelledMarker, marker
          line = line.replace cancelledRegex, ''
          line = line.replace projectRegex, ''
          line = line.trimRight()

        editor.setTextInBufferRange [bufferStart,bufferEnd], line
      editor.setSelectedBufferRanges ranges

  tasksUpdateTimestamp: ->
    # Update timestamps to match the current setting (only for tags though)
    editor = atom.workspace.getActiveEditor()
    editor.transact ->
      nText = editor.getText().replace /@done\(([^\)]+)\)/igm, (matches...)->
        "@done(#{moment(matches[1]).format(atom.config.get('tasks.dateFormat'))})"
      editor.setText nText

  tasksArchive: ->
    editor = atom.workspace.getActiveEditor()

    editor.transact ->
      ranges = editor.getSelectedBufferRanges()
      # move all completed tasks to the archive section
      text = editor.getText()
      raw = text.split('\n').filter (line)-> line isnt ''
      completed = []
      hasArchive = false

      original = raw.filter (line)->
        hasArchive = true if line.indexOf('Archive:') > -1
        found = doneRegex.test(line) or cancelledRegex.test(line)
        completed.push line.replace(/^[ \t]+/, Array(atom.config.get('editor.tabLength') + 1).join(' ')) if found
        not found

      newText = original.join('\n') +
        (if not hasArchive then "\n＿＿＿＿＿＿＿＿＿＿＿＿＿＿＿＿＿＿＿\nArchive:\n" else '\n') +
        completed.join('\n')

      if newText isnt text
        editor.setText newText
        editor.setSelectedBufferRanges ranges
