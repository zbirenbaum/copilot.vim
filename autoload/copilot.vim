if exists('g:autoloaded_copilot')
  finish
endif
let g:autoloaded_copilot = 1

scriptencoding utf-8

if len($XDG_CONFIG_HOME)
  let s:config_root = $XDG_CONFIG_HOME
elseif has('win32')
  let s:config_root = expand('~/AppData/Local')
else
  let s:config_root = expand('~/.config')
endif
let s:config_root .= '/github-copilot'
if !isdirectory(s:config_root)
  call mkdir(s:config_root, 'p', 0700)
endif

let s:config_hosts = s:config_root . '/hosts.json'

function! s:JsonBody(response) abort
  if get(a:response.headers, 'content-type', '') =~# '^application/json\>'
    let body = a:response.body
    return json_decode(type(body) == v:t_list ? join(body) : body)
  else
    throw 'Copilot: expected application/json but got ' . get(a:response.headers, 'content-type', 'no content type')
  endif
endfunction

function! copilot#HttpRequest(url, options, ...) abort
  return call('copilot#agent#Call', ['httpRequest', extend({'url': a:url}, a:options)] + a:000)
endfunction

function! s:AvailableAuth() abort
  let default_expires_at = localtime() + 86400
  if get(get(s:, 'auth_data', {}), 'expires_at') > localtime() + 600
    return s:auth_data
  else
    unlet! s:auth_data
  endif
  let api_key = get(g:, 'openai_api_key', $OPENAI_API_KEY)
  if len(api_key)
    return {'token': api_key, 'expires_at': default_expires_at}
  else
    return {}
  endif
endfunction

unlet! s:github
function! s:OAuthToken() abort
  if $CODESPACES ==# 'true' && len($GITHUB_TOKEN)
    return $GITHUB_TOKEN
  endif
  if exists('s:github')
    return get(s:github, 'oauth_token', '')
  endif
  if getfsize(s:config_hosts) > 0
    try
      let s:github = get(json_decode(join(readfile(s:config_hosts))), 'github.com')
    catch
      let s:github = {}
    endtry
  else
    return ''
  endif
  return get(s:github, 'oauth_token', {})
endfunction

function! s:OAuthSave(token) abort
  unlet! s:terms_accepted
  if len(a:token)
    let user_response = copilot#HttpRequest('https://api.github.com/user', {'headers': {'Authorization': 'Bearer ' . a:token}})
    let user_data = s:JsonBody(user_response)
    if get(user_response, 'status') == 200 && has_key(user_data, 'login')
      let s:github = {'oauth_token': a:token, 'user': user_data.login}
      call writefile(
            \ [json_encode({"github.com": s:github})],
            \ s:config_hosts)
      return 1
    endif
  endif
  let s:github = {}
  call delete(s:config_hosts)
endfunction

let s:terms_version = '2021-10-14'
unlet! s:terms_accepted

function! s:ReadTerms() abort
  let file = s:config_root . '/terms.json'
  try
    if filereadable(file)
      let terms = json_decode(join(readfile(file)))
      if type(terms) == v:t_dict
        return terms
      endif
    endif
  catch
  endtry
  return {}
endfunction

function! s:TermsAccepted() abort
  if exists('s:terms_accepted')
    return s:terms_accepted
  endif
  call s:OAuthToken()
  let file = s:config_root . '/terms.json'
  if exists('s:github.user') && filereadable(file)
    try
      let s:terms_accepted = s:ReadTerms()[s:github.user].version >= s:terms_version
      return s:terms_accepted
    endtry
  endif
  let s:terms_accepted = 0
  return s:terms_accepted
endfunction

function! s:AuthException(response, ...) abort
  unlet! s:auth_request
  let g:copilot_auth_exception = a:response
endfunction

function! s:AuthCallback(response, ...) abort
  unlet! s:auth_request
  let data = s:JsonBody(a:response)
  if a:response.status == 404
    call s:OAuthSave('')
  elseif has_key(data, 'token')
    let s:auth_data = data
  endif
endfunction

function! copilot#RefreshAuth() abort
  let token = s:OAuthToken()
  if !empty(token)
    if exists('s:auth_request')
      return
    endif
    let s:auth_request = copilot#HttpRequest(
          \ 'https://api.github.com/copilot_internal/token',
          \ {'headers': {'Authorization': 'Bearer ' . token}},
          \ function('s:AuthCallback'),
          \ function('s:AuthException'))
  endif
endfunction

function! copilot#FetchAuth() abort
  let auth = get(s:, 'auth_data', {})
  if get(auth, 'expires_at') < localtime() - 1800
    call copilot#RefreshAuth()
    return exists('s:auth_request')
  elseif get(auth, 'expires_at') < localtime() - 7200
    call copilot#RefreshAuth()
    return 0
  endif
endfunction

function! copilot#Auth() abort
  if copilot#FetchAuth()
    call copilot#agent#Wait(s:auth_request)
  endif
  return s:AvailableAuth()
endfunction

unlet! s:auth_data
unlet! s:auth_request

function! copilot#NvimNs() abort
  return nvim_create_namespace('github-copilot')
endfunction

function! copilot#Clear() abort
  if exists('g:copilot_timer')
    call timer_stop(remove(g:, 'copilot_timer'))
  endif
  if exists('g:copilot_completion')
    call copilot#agent#Cancel(remove(g:, 'copilot_completion'))
  endif
  call s:UpdatePreview()
endfunction

let s:filetype_defaults = {
      \ 'yaml': 0,
      \ 'markdown': 0,
      \ 'help': 0,
      \ 'gitcommit': 0,
      \ 'gitrebase': 0,
      \ 'hgcommit': 0,
      \ '_': 0}

function! s:FileTypeEnabled(filetype) abort
  let ft = empty(a:filetype) ? '_' : a:filetype
  return !empty(get(get(g:, 'copilot_filetypes', {}), ft, get(s:filetype_defaults, ft, 1)))
endfunction

function! copilot#Enabled() abort
  if !s:TermsAccepted() || !empty(copilot#agent#StartupError())
    return 0
  endif
  if !get(g:, 'copilot_enabled', 1)
    return 0
  endif
  if get(b:, 'copilot_disabled', 0)
    return 0
  endif
  return s:FileTypeEnabled(&filetype)
endfunction

function! copilot#Complete(...) abort
  if !s:TermsAccepted()
    return {}
  endif
  if exists('g:copilot_timer')
    call timer_stop(remove(g:, 'copilot_timer'))
  endif
  let doc = copilot#doc#Get()
  if !exists('g:copilot_completion') || g:copilot_completion.params.doc !=# doc
    let auth = copilot#Auth()
    if empty(auth)
      return {}
    endif
    let g:copilot_completion =
          \ copilot#agent#Send('getCompletions', {'doc': doc, 'options': {}, 'token': auth.token})
    let g:copilot_last_completion = g:copilot_completion
  endif
  let completion = g:copilot_completion
  if !a:0
    return copilot#agent#Await(completion)
  else
    call copilot#agent#Result(completion, a:1)
    if a:0 > 1
      call copilot#agent#Error(completion, a:2)
    endif
  endif
endfunction

function! s:CompletionTextWithAdjustments() abort
  try
    let choice = get(b:, '_copilot_completion', {})
    if !has_key(choice, 'range') || choice.range.start.line != line('.') - 1
      return ['', 0, 0]
    endif
    let line = getline('.')
    let offset = col('.') - 1
    if choice.range.start.character != 0
      call copilot#logger#Warn('unexpected range ' . json_encode(choice.range))
      return ['', 0, 0]
    endif
    let typed = strpart(line, 0, offset)
    let delete = strchars(strpart(line, offset))
    if typed ==# strpart(choice.text, 0, offset)
      return [strpart(choice.text, offset), 0, delete]
    elseif typed =~# '^\s*$'
      let leading = matchstr(choice.text, '^\s\+')
      if strpart(typed, 0, len(leading)) == leading
        return [strpart(choice.text, len(leading)), len(typed) - len(leading), delete]
      endif
    endif
  catch
    call copilot#logger#Exception()
  endtry
  return ['', 0, 0]
endfunction

function! s:ClearPreview() abort
  if exists('*nvim_buf_del_extmark')
    call nvim_buf_del_extmark(0, copilot#NvimNs(), 1)
  endif
endfunction

function! s:UpdatePreview() abort
  if !exists('*nvim_buf_get_mark') || !has('nvim-0.6')
    return
  endif
  if mode() !=# 'i' || pumvisible()
    return s:ClearPreview()
  endif
  try
    let [text, outdent, delete] = s:CompletionTextWithAdjustments()
    let text = split(text, "\n", 1)
    if empty(text[-1])
      call remove(text, -1)
    endif
    if empty(text)
      return s:ClearPreview()
    endif
    let data = {'id': 1}
    let data.virt_text_win_col = virtcol('.') - 1
    let hl = 'CopilotCompletion'
    let data.virt_text = [[text[0] . repeat(' ', delete - len(text[0])), hl]]
    if len(text) > 1
      let data.virt_lines = map(text[1:-1], { _, l -> [[l, hl]] })
    endif
    call nvim_buf_set_extmark(0, copilot#NvimNs(), line('.')-1, col('.')-1, data)
  catch
    return copilot#logger#Exception()
  endtry
endfunction

function! s:AfterComplete(result) abort
  if exists('a:result.completions')
    let b:_copilot_completion = get(a:result.completions, 0, {})
  else
    let b:_copilot_completion = {}
  endif
  call s:UpdatePreview()
endfunction

function! s:Trigger(bufnr, timer) abort
  let timer = get(g:, 'copilot_timer', -1)
  unlet! g:copilot_timer
  if a:bufnr !=# bufnr('') || a:timer isnot# timer || mode() !=# 'i'
    return
  endif
  if exists('s:auth_request')
    let g:copilot_timer = timer_start(100, function('s:Trigger', [a:bufnr]))
    return
  endif
  call copilot#Complete(function('s:AfterComplete'), function('s:AfterComplete'))
endfunction

function! copilot#Schedule(...) abort
  call copilot#Clear()
  if !copilot#Enabled()
    return
  endif
  call copilot#FetchAuth()
  let delay = a:0 ? a:1 : get(g:, 'copilot_idle_delay', 75)
  let g:copilot_timer = timer_start(delay, function('s:Trigger', [bufnr('')]))
endfunction

function! copilot#OnInsertLeave() abort
  unlet! b:_copilot_completion
  return copilot#Clear()
endfunction

function! copilot#OnInsertEnter() abort
  return copilot#Schedule()
endfunction

function! copilot#OnCompleteChanged() abort
  return copilot#Clear()
endfunction

function! copilot#OnCursorMovedI() abort
  return copilot#Schedule()
endfunction

function! copilot#Accept(...) abort
  let [text, outdent, delete] = s:CompletionTextWithAdjustments()
  if !empty(text)
    silent! call remove(b:, '_copilot_completion')
    return repeat("\<Left>\<Del>", outdent) . repeat("\<Del>", delete) .
            \ "\<C-R>\<C-O>=" . json_encode(text) . "\<CR>"
  endif
  return a:0 ? a:1 : ""
endfunction

function! copilot#Tab(...) abort
  return copilot#Accept(a:0 ? a:1 : get(g:, 'copilot_tab_fallback', pumvisible() ? "\<C-N>" : "\t"))
endfunction

function! copilot#OmniFunc(findstart, base) abort
  if a:findstart
    return col('.') - 1
  endif
  let complete = copilot#Complete()
  for choice in get(complete, 'completions', [])
    call complete_add({'word': matchstr(choice.displayText, "^[^\n]*")})
  endfor
  return []
endfunction

function! copilot#Status(...) abort
  if exists('g:copilot_timer')
    return 'copilot:scheduled'
  elseif exists('g:copilot_completion')
    return 'copilot:' . g:copilot_completion.status
  elseif !copilot#Enabled()
    return 'copilot:disabled'
  else
    return 'copilot:idle'
  endif
endfunction

function! s:DeviceResponse(result, login_data, poll_response) abort
  let data = s:JsonBody(a:poll_response)
  let should_cancel = get(get(s:, 'login_data', {}), 'device_code', '') !=# a:login_data.device_code
  if has_key(data, 'access_token')
    if !should_cancel
      unlet s:login_data
    endif
    let response = copilot#HttpRequest(
          \ 'https://api.github.com/copilot_internal/token',
          \ {'headers': {'Authorization': 'Bearer ' . data.access_token}})
    if response.status ==# 404
      let a:result.status = 0
      let a:result.error = "You don't have access to GitHub Copilot. Join the waitlist by visiting https://copilot.github.com"
    else
      let a:result.status = 1
      call s:OAuthSave(data.access_token)
    endif
  elseif should_cancel
    let a:result.status = 0
    let a:result.error = "Something went wrong."
  elseif has_key(a:result, 'status')
    return
  elseif index(['authorization_pending', 'slow_down'], get(data, 'error', '')) != -1
    call timer_start((get(data, 'interval', a:login_data.interval)+1) * 1000, function('s:DevicePoll', [a:result, a:login_data]))
  elseif has_key(data, 'error_description')
    let a:result.status = 0
    let a:result.error = data.error_description
    unlet! s:login_data
    echohl ErrorMsg
    echomsg 'Copilot: ' . data.error_description
    echohl NONE
  else
    let a:result.status = 0
    let a:result.error = "Something went wrong."
  endif
endfunction

let s:client_id = "Iv1.b507a08c87ecfe98"

function! s:DevicePoll(result, login_data, timer) abort
  call copilot#HttpRequest(
        \ 'https://github.com/login/oauth/access_token?grant_type=urn:ietf:params:oauth:grant-type:device_code&device_code=' . a:login_data.device_code . '&client_id=' . s:client_id,
        \ {'headers': {'Accept': 'application/json'}},
        \ function('s:DeviceResponse', [a:result, a:login_data]))
endfunction

function! copilot#Browser() abort
  if type(get(g:, 'copilot_browser')) == v:t_list
    return copy(g:copilot_browser)
  elseif has('win32') && executable('rundll32')
    return ['rundll32', 'url.dll,FileProtocolHandler']
  elseif isdirectory('/private') && executable('/usr/bin/open')
    return ['/usr/bin/open']
  elseif executable('gio')
    return ['gio', 'open']
  elseif executable('xdg-open')
    return ['xdg-open']
  else
    return []
  endif
endfunction

let s:commands = {}

function! s:commands.setup(opts) abort
  let response = copilot#HttpRequest('https://copilot-proxy.githubusercontent.com/_ping',
        \ {'headers': {'Agent-Version': copilot#agent#Version()}})
  if response.status == 466
    return 'echoerr ' . string('Copilot: Plugin upgrade required')
  endif

  let browser = copilot#Browser()

  if empty(s:OAuthToken()) || empty(copilot#Auth()) || a:opts.bang
    let response = copilot#HttpRequest('https://github.com/login/device/code', {
          \ 'method': 'POST',
          \ 'headers': {'Accept': 'application/json'},
          \ 'json': {'client_id': s:client_id, 'scope': 'read:user'}})
    let data = s:JsonBody(response)
    let s:login_data = data
    let @+ = data.user_code
    let @* = data.user_code
    echo "First copy your one-time code: " . data.user_code
    if len(browser)
      echo "Press ENTER to open github.com in your browser"
      try
        if len(&mouse)
          let mouse = &mouse
          set mouse=
        endif
        let c = getchar()
        while c isnot# 13 && c isnot# 10 && c isnot# 0
          let c = getchar()
        endwhile
      finally
        if exists('mouse')
          let &mouse = mouse
        endif
      endtry
      let exit_status = copilot#job#Stream(browser + [data.verification_uri], v:null, v:null)
      if exit_status
        echo "Failed to open browser.  Visit " . data.verification_uri
      else
        redraw
      endif
    else
      echo "Could not find browser.  Visit " . data.verification_uri
    endif
    echo "Waiting (could take up to 5 seconds)"
    let result = {}
    call timer_start((data.interval+1) * 1000, function('s:DevicePoll', [result, data]))
    try
      while !has_key(result, 'status')
        sleep 100m
      endwhile
    finally
      if !has_key(result, 'status')
        let result.status = 0
        let result.error = "Interrupt"
      endif
      redraw
    endtry
    if !result.status
      return 'echoerr ' . string('Copilot: Authentication failure: ' . result.error)
    endif
  endif

  unlet! s:terms_accepted
  if !s:TermsAccepted()
    let terms_url = "https://github.co/copilot-telemetry-terms"
    echo "I agree to these telemetry terms as part of the GitHub Copilot technical preview."
    echo "<" . terms_url . ">"
    let prompt = '[a]gree/[r]efuse'
    if len(browser)
      let prompt .= '/[o]pen in browser'
    endif
    while 1
      let input = input(prompt . '> ')
      if input =~# '^r'
        redraw
        return 'echoerr ' . string('Copilot: Terms must be accepted.')
      elseif input =~# '^[ob]' && len(browser)
        if copilot#job#Stream(browser + [terms_url], v:null, v:null) != 0
          echo "\nCould not open browser."
        endif
      elseif input =~# '^a'
        break
      else
        echo "\nUnrecognized response."
      endif
    endwhile
    redraw
    let terms = s:ReadTerms()
    let terms[s:github.user] = {'version': s:terms_version}
    call writefile([json_encode(terms)], s:config_root . '/terms.json')
    unlet! s:terms_accepted
  endif
  let success = "Copilot: All systems go!"
  if !exists('*nvim_buf_get_mark') || !has("nvim-0.6")
    echohl WarningMsg
    echo "Copilot: Neovim nightly build required to support ghost text."
    echohl NONE
  elseif !get(g:, 'copilot_enabled', 1)
    echo success . '  Re-enable with :Copilot enable'
  elseif get(b:, 'copilot_disabled', 0)
    echo 'Copilot: All systems go!  Disabled for current buffer'
  elseif !s:FileTypeEnabled(&filetype)
    echo success . "  Disabled for the file type '" . &filetype . "'"
  elseif !copilot#Enabled()
    echo 'Copilot: Something is wrong with enabling/disabling'
  else
    echo sucess
  endif
endfunction

function! s:commands.help(opts) abort
  return a:opts.mods . ' help copilot'
endfunction

function! s:commands.log(opts) abort
  return a:opts.mods . ' split +$ ' . fnameescape(copilot#logger#File())
endfunction

function! s:commands.restart(opts) abort
  call copilot#agent#Close()
  let err = copilot#agent#StartupError()
  if !empty(err)
    return 'echoerr ' . string('Copilot: ' . err)
  endif
  echo 'Copilot: Restarting agent.'
endfunction

function! s:commands.disable(opts) abort
  let g:copilot_enabled = 0
endfunction

function! s:commands.enable(opts) abort
  let g:copilot_enabled = 1
endfunction

function! s:commands.toggle(opts) abort
  let g:copilot_enabled = !get(g:, 'copilot_enabled', 1)
  if g:copilot_enabled
    echo 'Copilot enabled.'
  else
    echo 'Copilot disabled.'
  endif
endfunction

function! copilot#CommandComplete(arg, lead, pos) abort
  let args = matchstr(strpart(a:lead, 0, a:pos), 'C\%[opilot][! ] *\zs.*')
  if args !~# ' '
    return sort(filter(map(keys(s:commands), { k, v -> tr(v, '_', '-') }),
          \ { k, v -> strpart(v, 0, len(a:arg)) ==# a:arg }))
  else
    return []
  endif
endfunction

function! copilot#Command(line1, line2, range, bang, mods, arg) abort
  let err = copilot#agent#StartupError()
  if !empty(err)
    return 'echoerr ' . string('Copilot: ' . err)
  endif
  let cmd = matchstr(empty(a:arg) ? 'setup' : a:arg, '^\%(\\.\|\S\)\+')
  let arg = matchstr(a:arg, '\s\zs\S.*')
  if !has_key(s:commands, tr(cmd, '-', '_'))
    return 'echoerr ' . string('Copilot: unknown command ' . string(cmd))
  endif
  let opts = {'line1': a:line1, 'line2': a:line2, 'range': a:range, 'bang': a:bang, 'mods': a:mods, 'arg': arg}
  let retval = s:commands[tr(cmd, '-', '_')](opts)
  if type(retval) == v:t_string
    return retval
  else
    return ''
  endif
endfunction
