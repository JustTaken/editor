# Inspiration
A text editor inspired by [Emacs](https://www.gnu.org/software/emacs/).
In my opinion the most productive way of editing text is using emacs binding,
because being in editing mode all the time gives you the flexibility
to change the cursor position with less hand movements, and feels
smother in comparison with modal editing in [Vim](https://www.vim.org/) case.

## why not emacs then?
That is a preference, i don't like emacs way of pushing features into
the user, emacs does a lot of things in many diferent ways, for
example, greping a public function definition in your zig code base,
you can do `M-x compile` then `grep -re "^\s*pub fn"`, or you could
use `M-x project-find-regexp` and use the same regex, or you could go
into `dired-mode` and mark the file paths you want to search with `m`
and use the command `dired-do-find-regexp`, and so on. This is just
one example, in my understanding a text editor should help you in reading,
finding and editing text, just that.
