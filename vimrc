" Use Vim settings, rather then Vi settings. This must be first, because it
" changes other options as a side effect.
set nocompatible

" Insert two spaces after a '.', '?' and '!' with a join command.  When
" 'cpoptions' includes the 'j' flag, only do this after a '.'.  Otherwise only
" one space is inserted.
set nojoinspaces

" Allow backspacing over everything in insert mode
set backspace=indent,eol,start

" When a file has been detected to have been changed outside of Vim and it has
" not been changed inside of Vim, automatically read it again.
set autoread

" Write the contents of the file, if it has been modified, on each :next,
" :rewind, :last, :first, :previous...
set autowrite

" Make a backup before overwriting a file.
set backup

" Sets the character encoding used inside Vim.
set encoding=utf-8

" In Insert mode: Use the appropriate number of spaces to insert a <Tab>.
set expandtab

" Number of spaces that a <Tab> in the file counts for.
set tabstop=4

" This option changes how text is displayed.  It doesn't change the text in
" the buffer, see 'textwidth' for that.
set nowrap

" Minimal number of screen lines to keep above and below the cursor. This will
" make some context visible around where you are working.
set scrolloff=3

" The minimal number of columns to scroll horizontally.  Used only when the
" 'wrap' option is off and the cursor is moved off of the screen. When it is
" zero the cursor will be put in the middle of the screen.
set sidescroll=5

" The minimal number of screen columns to keep to the left and to the right of
" the cursor if 'nowrap' is set.  Setting this option to a value greater than
" 0 while having |'sidescroll'| also at a non-zero value makes some context
" visible in the line you are scrolling in horizontally (except at beginning
" of the line).
set sidescrolloff=3

" Strings to use in 'list' mode and for the |:list| command.  It is a comma
" separated list of string settings.
set listchars+=precedes:<,extends:>

" Number of spaces to use for each step of (auto)indent.
set shiftwidth=4

" Number of spaces that a <Tab> counts for while performing editing
" operations, like inserting a <Tab> or using <BS>.  It "feels" like <Tab>s
" are being inserted, while in fact a mix of spaces and <Tab>s is used.
set softtabstop=4

" Maximum number of tab pages to be opened by the |-p| command line argument
" or the ":tab all" command.
set tabpagemax=20

" Round indent to multiple of 'shiftwidth'.  Applies to > and < commands.
" CTRL-T and CTRL-D in Insert mode always round the indent to a multiple of
" 'shiftwidth' (this is Vi compatible).
set shiftround

" A <Tab> in front of a line inserts blanks according to 'shiftwidth'.
" 'tabstop' or 'softtabstop' is used in other places.  A <BS> will delete a
" 'shiftwidth' worth of space at the start of the line.
set smarttab

" When on, Vim automatically saves undo history to an undo file when writing a
" buffer to a file, and restores undo history from the same file on buffer
" read.
set undofile

" List of directory names for undo files, separated with commas.
set undodir=~/.vim/undo

" Maximum number of changes that can be undone.  Since undo information is
" kept in memory, higher numbers will cause more memory to be used
" (nevertheless, a single change can use an unlimited amount of memory).
set undolevels=1500

" Use the 'history' option to set the number of lines that are remembered
" (default: 50).
set history=50

" While typing a search command, show where the pattern, as it was typed so
" far, matches.  The matched string is highlighted.  If the pattern is invalid
" or not found, nothing is shown.  The screen will be updated often, this is
" only useful on fast terminals.
set incsearch

" If 'modeline' is on 'modelines' gives the number of lines that is checked
" for set commands.
set modeline
set modelines=20

" String to put at the start of lines that have been wrapped.  Useful values
" are "> " or "+++ ":
set showbreak="+++ "

" Show (partial) command in the last line of the screen.
set showcmd

" When a bracket is inserted, briefly jump to the matching one.  The jump is
" only done if the match can be seen on the screen.  The time to show the
" match can be set with 'matchtime'.
set showmatch

" If on, Vim will wrap long lines at a character in 'breakat' rather than at
" the last character that fits on the screen.  Unlike 'wrapmargin' and
" 'textwidth', this does not insert <EOL>s in the file, it only affects the
" way the file is displayed, not its contents.
set linebreak

" Precede each line with its line number.
set number

" Copy the structure of the existing lines indent when autoindenting a new
" line.
set copyindent

" Show the line and column number of the cursor position.
set ruler

" The value of this option influences when the last window will have a status
" line: 0: never, 1: only if there are at least two windows, 2: always.
set laststatus=2

" Maximum width of text that is being inserted.  A longer line will be broken
" after white space to get this width.
set textwidth=78

" When non-empty, the viminfo file is read upon startup and written when
" exiting Vim (see |viminfo-file|).  The string should be a comma separated
" list of parameters, each consisting of a single character identifying the
" particular parameter, followed by a number or string which specifies the
" value of that parameter.  If a particular character is left out, then the
" default value is used for that parameter.  The following is a list of the
" identifying characters and
"
" "	Maximum number of lines saved for each register.  Old name of the '<'
"   item, with the disadvantage that you need to put a backslash before the ",
"   otherwise it will be recognized as the start of a comment!
"
" '	Maximum number of previously edited files for which the marks are
"   remembered.  This parameter must always be included when 'viminfo' is
"   non-empty.  Including this item also means that the |jumplist| and the
"   |changelist| are stored in the viminfo file.
set viminfo='20,\"500

" Completion mode that is used for the character specified with 'wildchar'.
" It is a comma separated list of up to four parts.  Each part specifies what
" to do for each consecutive use of 'wildchar'.  The first part specifies the
" behavior for the first use of 'wildchar', The second part for the second
" use, etc.set wildmode=longest:full
set wildmenu

" Completion mode that is used for the character specified with 'wildchar'.
" It is a comma separated list of up to four parts.  Each part specifies what
" to do for each consecutive use of 'wildchar'.  The first part specifies the
" behavior for the first use of 'wildchar', The second part for the second
" use, etc.
set wildmode=longest,list

set printoptions=paper:letter,number:y,portrait:y
set printfont=courier:h6

" List of directories for the backup file, separated with commas.
set backupdir=~/.vim/backup,.

" List of directory names for the swap file, separated with commas.
set dir=~/.vim/swap,.

" Use visual bell instead of beeping.
set visualbell

" Indent Fortran loops.
let fortran_do_enddo = 1

" Some more precise Fortran syntaxing.
let fortran_more_precise = 1

" Options for gnupg plugin.
"let g:GPGDebug = 1
"let g:GPGDebugLevel = 5
"let g:GPGDebugLog = "/tmp/gpg.debug"
let g:GPGPreferArmor = 1

" Python indent settings.
let g:pyindent_open_paren = '&shiftwidth'
let g:pyindent_nested_paren = '&shiftwidth'
let g:pyindent_continue = '&shiftwidth'

" This option enables "on the fly" code checking
let g:pymode_lint_onfly = 1

" Hightlight `print` as function
let g:pymode_syntax_print_as_function = 1

" If set, ropevim will open a new buffer for "go to definition" result if the
" definition found is located in another file. By default the file is open in
" the same buffer.  Values: '' -- same buffer, 'new' -- horizontally split,
" 'vnew' -- vertically splitlet
let g:pymode_goto_def_newwin = 'new'

" So we can use man pages.
runtime ftplugin/man.vim

if &t_Co > 2 || has("gui_running")

    syntax on
    set hlsearch
    colorscheme darkblue

endif

if has("gui_running")
    set guifont=Monospace\ 12
endif

if has("autocmd")

    filetype on
    filetype plugin on
    filetype indent on

    " When editing a file, always jump to the last known cursor position.  Don't
    " do it when the position is invalid or when inside an event handler
    " (happens when dropping a file on gvim). Also don't do it when the mark is
    " in the first line, that is the default position when opening a file.
    autocmd BufReadPost *
                \ if line("'\"") > 0 && line("'\"") <= line("$") |
                \   exe "normal g'\"" |
                \ endif

    " Check whether the file in a buffer has been modified outside of vi.
    autocmd BufEnter * checktime

    " Toggle between absolute and relative line numbers.
    "autocmd InsertEnter * :set number
    "autocmd InsertLeave * :set relativenumber
    "autocmd CursorMoved * :set relativenumber

    autocmd BufRead,BufNewFile *.ini.erb set filetype=dosini

    " Set filetype specific options.
    autocmd Filetype cmake setlocal tabstop=2 shiftwidth=2 softtabstop=2
    autocmd Filetype gitcommit setlocal spell spelllang=en,de formatoptions-=a textwidth=72
    autocmd Filetype go setlocal noexpandtab
    autocmd Filetype python setlocal noautowrite
    autocmd Filetype rst setlocal spell spelllang=en,de
    autocmd Filetype ruby setlocal tabstop=2 shiftwidth=2 softtabstop=2
    autocmd Filetype tex setlocal tabstop=2 shiftwidth=2 softtabstop=2 spell

    " Some mail settings (for mutt)
    autocmd Filetype mail setlocal formatoptions+=aw wrap number textwidth=66 spell spelllang=en,de

endif
