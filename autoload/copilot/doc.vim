if exists('g:autoloaded_copilot_prompt')
  finish
endif
let g:autoloaded_copilot_prompt = 1

scriptencoding utf-8

function copilot#doc#UTF16Width(str) abort
  return strchars(substitute(a:str, "[^\u0001-\uffff]", "  ", 'g'))
endfunction

let s:language_normalization_map = {
      \ "javascriptreact": "javascript",
      \ "jsx":             "javascript",
      \ "typescriptreact": "typescript",
      \ }

function copilot#doc#LanguageForFileType(filetype) abort
  let filetype = substitute(a:filetype, '\..*', '', '')
  return get(s:language_normalization_map, filetype, filetype)
endfunction

function! s:Path() abort
  return get(b:, 'copilot_relative_path', @%)
endfunction

function! copilot#doc#Get() abort
  let doc = {
        \ 'languageId': copilot#doc#LanguageForFileType(&filetype),
        \ 'path': expand('%:p'),
        \ 'relativePath': s:Path(),
        \ 'insertSpaces': &expandtab ? v:true : v:false,
        \ 'tabSize': shiftwidth(),
        \ 'indentSize': shiftwidth(),
        \ }
  let line = getline('.')
  let col_byte = col('.') - (mode() ==# 'i' || empty(line))
  let col_utf16 = copilot#doc#UTF16Width(strpart(line, 0, col_byte))
  let doc.position = {'line': line('.') - 1, 'character': col_utf16}
  let lines = getline(1, '$')
  if &eol
    call add(lines, "")
  endif
  let doc.source = join(lines, "\n")
  return doc
endfunction
