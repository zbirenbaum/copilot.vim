if exists('g:loaded_copilot')
  finish
endif
let g:loaded_copilot = 1

scriptencoding utf-8

function! s:ColorScheme() abort
  if &t_Co == 256
    hi def CopilotCompletion guifg=#808080 ctermfg=244
  else
    hi def CopilotCompletion guifg=#808080 ctermfg=8
  endif
endfunction

function! s:Event(type) abort
  try
    call call('copilot#On' . a:type, [])
  catch
    call copilot#logger#Exception()
  endtry
endfunction

augroup github_copilot
  autocmd!
  autocmd InsertLeave          * call s:Event('InsertLeave')
  autocmd BufLeave             * if mode() =~# '^[iR]'|call s:Event('InsertLeave')|endif
  autocmd InsertEnter          * call s:Event('InsertEnter')
  autocmd BufEnter             * if mode() =~# '^[iR]'|call s:Event('InsertEnter')|endif
  autocmd CursorMovedI         * call s:Event('CursorMovedI')
  autocmd CompleteChanged      * call s:Event('CompleteChanged')
  autocmd ColorScheme,VimEnter * call s:ColorScheme()
  autocmd VimEnter             * call copilot#agent#Start()
augroup END

call s:ColorScheme()

command! -bang -nargs=? -range=-1 -complete=customlist,copilot#CommandComplete Copilot exe copilot#Command(<line1>, <count>, +"<range>", <bang>0, "<mods>", <q-args>)

inoremap <silent><expr><nowait> <Plug>(copilot-accept) copilot#Accept()
inoremap <silent><expr><nowait> <Plug>(copilot-tab) copilot#Tab()

let s:tab_map = maparg("<Tab>", "i", 0, 1)
if empty(s:tab_map)
  inoremap <silent><expr><nowait> <Tab> copilot#Tab()
elseif s:tab_map.expr
  if s:tab_map.rhs !~? 'copilot'
    exe 'inoremap <silent><expr><nowait> <Tab> copilot#Tab(' . s:tab_map.rhs . ')'
  endif
else
  exe 'inoremap <silent><expr><nowait> <Tab> copilot#Tab(' . string(s:tab_map.rhs) . ')'
endif

let s:dir = expand('<sfile>:h:h')
if getftime(s:dir . '/doc/copilot.txt') > getftime(s:dir . '/doc/tags')
  silent! execute 'helptags' fnameescape(s:dir . '/doc')
endif
