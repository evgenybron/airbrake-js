require('./internal/compat')
merge = require('./internal/merge')
Promise = require('./internal/promise')


# Creates window.onerror handler for notifier. See
# https://developer.mozilla.org/en/docs/Web/API/GlobalEventHandlers/onerror.
makeOnErrorHandler = (notifier) ->
  (message, file, line, column, error) ->
    if error
      notifier.notify(error)
    else
      notifier.notify({error: {
        message: message,
        fileName: file,
        lineNumber: line,
        columnNumber: column or 0,
      }})


class Client
  constructor: (opts={}) ->
    @_projectId = opts.projectId || 0
    @_projectKey = opts.projectKey || ''

    @_host = opts.host || 'https://api.airbrake.io'

    @_processor = null
    @_reporters = []
    @_filters = []

    if opts.processor != undefined
      @_processor = opts.processor
    else
      @_processor = require('./processors/stack')

    if opts.reporter != undefined
      @addReporter(opts.reporter)
    else
      if 'withCredentials' of new global.XMLHttpRequest()
        reporter = 'compat'
      else
        reporter = 'jsonp'
      @addReporter(reporter)

    @addFilter(require('./internal/script_error_filter'))

    @onerror = makeOnErrorHandler(this)
    if not global.onerror? and opts.onerror != false
      global.onerror = @onerror

  setProject: (id, key) ->
    @_projectId = id
    @_projectKey = key

  setHost: (host) ->
    @_host = host

  addReporter: (reporter) ->
    switch reporter
      when 'compat'
        reporter = require('./reporters/compat')
      when 'xhr'
        reporter = require('./reporters/xhr')
      when 'jsonp'
        reporter = require('./reporters/jsonp')
    @_reporters.push(reporter)

  addFilter: (filter) ->
    @_filters.push(filter)

  notify: (err) ->
    context = {
      language: 'JavaScript'
      sourceMapEnabled: true
    }
    if global.navigator?.userAgent
      context.userAgent = global.navigator.userAgent
    if global.location
      context.url = String(global.location)
      # Set root directory to group errors on different subdomains together.
      context.rootDirectory = global.location.protocol + '//' + global.location.host

    promise = new Promise()

    @_processor err.error or err, (processorName, errInfo) =>
      notice =
        errors: [errInfo]
        context: merge(context, err.context)
        params: err.params or {}
        environment: err.environment or {}
        session: err.session or {}

      notice.context.notifier =
        name: 'airbrake-js-' + processorName
        version: '<%= pkg.version %>'
        url: 'https://github.com/airbrake/airbrake-js'

      for filterFn in @_filters
        notice = filterFn(notice)
        if notice == null or notice == false
          return

      opts = {projectId: @_projectId, projectKey: @_projectKey, host: @_host}
      for reporterFn in @_reporters
        reporterFn(notice, opts, promise)

      return

    return promise

  _wrapArguments: (args) ->
    for arg, i in args
      if typeof arg == 'function'
        args[i] = @wrap(arg)
    return args

  wrap: (fn) ->
    if fn.__airbrake__
      return fn

    self = this

    airbrakeWrapper = ->
      args = self._wrapArguments(arguments)
      try
        return fn.apply(this, args)
      catch exc
        args = Array.prototype.slice.call(arguments)
        self.notify({error: exc, params: {arguments: args}})
        return

    for prop of fn
      if fn.hasOwnProperty(prop)
        airbrakeWrapper[prop] = fn[prop]

    airbrakeWrapper.__airbrake__ = true
    airbrakeWrapper.__inner__ = fn

    return airbrakeWrapper


module.exports = Client
