if exists('g:autoloaded_copilot_agent')
  finish
endif
let g:autoloaded_copilot_agent = 1

scriptencoding utf-8

let s:error_exit = -1

let s:root = expand('<sfile>:h:h:h')

function! s:AgentClose() dict abort
  if exists('*chanclose')
    call chanclose(self.job, 'stdin')
  else
    call ch_close_in(self.job)
  endif
endfunction

function! s:LogSend(request, line) abort
  if type(get(a:request, 'params')) == v:t_dict && has_key(a:request.params, 'token')
    let request = deepcopy(a:request)
    let request.params.token = 'REDACTED'
    let line = json_encode(request)
  else
    let line = a:line
  endif
  return '--> ' . line
endfunction

let s:chansend = function(exists('*chansend') ? 'chansend' : 'ch_sendraw')
function! s:Transmit(agent, request) abort
  let request = extend({'jsonrpc': '2.0'}, a:request, 'keep')
  let line = json_encode(request)
  call s:chansend(a:agent.job, line . "\n")
  call copilot#logger#Trace(function('s:LogSend', [request, line]))
  return request
endfunction

function! s:AgentNotify(method, params) dict abort
  return s:Transmit(self, {'method': a:method, 'params': a:params})
endfunction

if !exists('s:id')
  let s:id = 0
endif
function! s:AgentSend(method, params, ...) dict abort
  let s:id += 1
  let request = {'method': a:method, 'params': a:params, 'id': s:id}
  call s:Transmit(self, request)
  call extend(request, {'resolve': [], 'reject': [], 'status': 'running'})
  let self.requests[s:id] = request
  if a:0
    call add(request.resolve, a:1)
  endif
  if a:0 > 1
    call add(request.reject, a:2)
  endif
  return request
endfunction

function! s:AgentCall(method, params, ...) dict abort
  let request = call(self.Send, [a:method, a:params] + a:000)
  if a:0
    return request
  endif
  return copilot#agent#Await(request)
endfunction

function! s:AgentCancel(request) dict abort
  if has_key(self.requests, get(a:request, 'id', ''))
    call remove(self.requests, a:request.id)
  endif
  if a:request.status ==# 'running'
    let a:request.status = 'canceled'
  endif
endfunction

function! s:OnOut(agent, line) abort
  call copilot#logger#Trace({ -> '<-- ' . a:line})
  try
    let response = json_decode(a:line)
  catch
    return copilot#logger#Exception()
  endtry
  if type(response) != v:t_dict
    return
  endif

  let id = get(response, 'id', v:null)
  if has_key(response, 'method')
    return a:agent.Transmit({"id": id, "code": -32700, "message": "Method not found: " . method})
  endif
  if !has_key(a:agent.requests, id)
    return
  endif
  let request = remove(a:agent.requests, id)
  if request.status ==# 'canceled'
    return
  endif
  let request.waiting = {}
  let resolve = remove(request, 'resolve')
  let reject = remove(request, 'reject')
  if has_key(response, 'result')
    let request.status = 'success'
    let request.result = response.result
    for Cb in resolve
      let request.waiting[timer_start(0, function('s:Callback', [request, 'result', Cb]))] = 1
    endfor
  else
    let request.status = 'error'
    let request.error = response.error
    for Cb in reject
      let request.waiting[timer_start(0, function('s:Callback', [request, 'error', Cb]))] = 1
    endfor
  endif
endfunction

function! s:OnErr(agent, line) abort
  call copilot#logger#Debug('<-! ' . a:line)
endfunction

function! s:OnExit(agent, code) abort
  if a:agent is# get(s:, 'instance')
    let instance = remove(s:, 'instance')
    for id in sort(keys(instance.requests), { a, b -> a > b })
      let request = remove(instance, id)
      let request.status = 'error'
      let request.error = {'code': s:error_exit, 'message': 'Agent exited', 'data': {'status': a:code}}
      for Cb in reject
        let request.waiting[timer_start(0, function('s:Callback', [request, 'error', Cb]))] = 1
      endfor
    endfor
    call copilot#logger#Info('agent exited with status ' . a:code)
  endif
endfunction

function! copilot#agent#Close() abort
  if exists('s:instance')
    let instance = remove(s:, 'instance')
    call instance.Close()
    call copilot#logger#Info('agent stopped')
  endif
endfunction

function! copilot#agent#StartupError() abort
  if !has('nvim-0.5') && v:version < 802
    return 'Vim version too old'
  endif
  if exists('s:instance')
    return ''
  endif
  let node = get(g:, 'copilot_node_command', 'node')
  if type(node) == type('')
    let node = [node]
  endif
  if !executable(get(node, 0, ''))
    if get(node, 0, '') ==# 'node'
      return 'Node not found in PATH'
    else
      return 'Node executable `' . get(node, 0, '') . "' not found"
    endif
  endif
  let out = []
  let err = []
  let status = copilot#job#Stream(node + ['--version'], function('add', [out]), function('add', [err]))
  if status != 0
    return 'Node exited with status ' . status
  endif
  let major = +matchstr(get(out, 0, ''), '^v\zs\d\+\ze\.')
  if major < 12
    return 'Node v12+ required but found ' . get(out, 0, 'nothing')
  endif
  let agent = s:root . '/copilot/dist/agent.js'
  if !filereadable(agent)
    let agent = get(g:, 'copilot_agent_command', '')
    if !filereadable(agent)
      return 'Could not find agent.js (bad install?)'
    endif
  endif
  let instance = {'requests': {},
        \ 'Close': function('s:AgentClose'),
        \ 'Notify': function('s:AgentNotify'),
        \ 'Send': function('s:AgentSend'),
        \ 'Call': function('s:AgentCall'),
        \ 'Cancel': function('s:AgentCancel'),
        \ }
  let instance.job = copilot#job#Stream(node + [agent],
        \ function('s:OnOut', [instance]),
        \ function('s:OnErr', [instance]),
        \ function('s:OnExit', [instance]))
  let request = instance.Send('getVersion', {})
  call copilot#agent#Wait(request)
  if request.status ==# 'error'
    if request.error.code == s:error_exit
      return 'Agent exited with status ' . request.error.data.status
    else
      call instance.Close()
      return 'Unexpected error ' . request.error.code . ' calling agent: ' . request.error.message
    endif
  endif
  let instance.version = request.result.version
  let s:instance = instance
  call copilot#logger#Info('agent started')
  return ''
endfunction

function! copilot#agent#Start() abort
  return empty(copilot#agent#StartupError())
endfunction

function! copilot#agent#Instance() abort
  let err = copilot#agent#StartupError()
  if empty(err)
    return s:instance
  endif
  throw 'Copilot: ' . err
endfunction

function! copilot#agent#Restart() abort
  call copilot#agent#Close()
  return copilot#agent#Instance()
endfunction

function! copilot#agent#Version()
  let instance = copilot#agent#Instance()
  return instance.version
endfunction

function! copilot#agent#Notify(method, params) abort
  let instance = copilot#agent#Instance()
  return instance.Notify(a:method, a:params)
endfunction

function! copilot#agent#Send(method, params, ...) abort
  let instance = copilot#agent#Instance()
  return call(instance.Send, [a:method, a:params] + a:000)
endfunction

function! copilot#agent#Cancel(request) abort
  if exists('s:instance')
    call s:instance.Cancel(a:request)
  endif
  if a:request.status ==# 'running'
    let a:request.status = 'canceled'
  endif
endfunction

function! s:Callback(request, type, callback, timer) abort
  call remove(a:request.waiting, a:timer)
  if has_key(a:request, a:type)
    call a:callback(a:request[a:type])
  endif
endfunction

function! copilot#agent#Result(request, callback) abort
  if has_key(a:request, 'resolve')
    call add(a:request.resolve, a:callback)
  elseif has_key(a:request, 'result')
    let a:request.waiting[timer_start(0, function('s:Callback', [a:request, 'result', a:callback]))] = 1
  endif
endfunction

function! copilot#agent#Error(request, callback) abort
  if has_key(a:request, 'reject')
    call add(a:request.reject, a:callback)
  elseif has_key(a:request, 'error')
    let a:request.waiting[timer_start(0, function('s:Callback', [a:request, 'error', a:callback]))] = 1
  endif
endfunction

function! copilot#agent#Wait(request) abort
  if type(a:request) !=# type({}) || !has_key(a:request, 'status')
    throw string(a:request)
  endif
  while a:request.status ==# 'running'
    sleep 1m
  endwhile
  while !empty(get(a:request, 'waiting', {}))
    sleep 1m
  endwhile
  return a:request
endfunction

function! copilot#agent#Await(request) abort
  call copilot#agent#Wait(a:request)
  if has_key(a:request, 'result')
    return a:request.result
  endif
  throw 'copilot#agent(' . a:request.error.code . '): ' . a:request.error.message
endfunction

function! copilot#agent#Call(method, params, ...) abort
  let instance = copilot#agent#Instance()
  return call(instance.Call, [a:method, a:params] + a:000)
endfunction
