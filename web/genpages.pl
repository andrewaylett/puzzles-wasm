#!/usr/bin/perl

# Generates the browser front end's static web pages: one per puzzle
# (using that puzzle's own <name>-midend.wasm, so no in-page picker
# is needed) plus an index page linking to all of them - the
# WASM-mid-end equivalent of html/jspage.pl's per-puzzle canvas-build
# pages.
#
# Usage: genpages.pl <outdir> <has-help:0|1> \
#          <name1> <displayname1> <description1> <unfinished1:0|1> ...
#
# Run from CMake (cmake/platforms/emscripten.cmake), which supplies
# the per-puzzle metadata already known to the build (DISPLAYNAME,
# DESCRIPTION from each puzzle() call in CMakeLists.txt, and whether
# the puzzle lives under unfinished/).

use strict;
use warnings;

my $outdir = shift @ARGV or die "genpages.pl: no output directory given\n";
my $has_help = shift @ARGV;
die "genpages.pl: no puzzle metadata given\n" unless @ARGV;
die "genpages.pl: puzzle metadata must come in quads\n" if @ARGV % 4;

my @games;
while (@ARGV) {
    my ($name, $displayname, $description, $unfinished) = splice(@ARGV, 0, 4);
    push @games, { name => $name, displayname => $displayname,
                   description => $description, unfinished => $unfinished };
}

sub html_escape {
    my ($s) = @_;
    $s =~ s/&/&amp;/g;
    $s =~ s/</&lt;/g;
    $s =~ s/>/&gt;/g;
    $s =~ s/"/&quot;/g;
    return $s;
}

sub write_file {
    my ($path, $content) = @_;
    open my $fh, ">", $path or die "$path: open: $!\n";
    print $fh $content;
    close $fh;
}

for my $g (@games) {
    my $name = $g->{name};
    my $displayname = html_escape($g->{displayname});
    my $description = html_escape($g->{description});
    my $unfinished = $g->{unfinished};

    my $help_link = "";
    if ($has_help && !$unfinished) {
        $help_link = qq{<a href="help/${name}.html">Full instructions</a>\n    | };
    }
    my $unfinished_note = "";
    if ($unfinished) {
        $unfinished_note = qq{<p><em>This is an unfinished puzzle, not \
linked from the <a href="index.html">main puzzles page</a>. Don't be \
surprised if things are hard to understand or don't work as \
expected.</em></p>\n};
    }

    write_file("${outdir}/${name}.html", <<EOF);
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>${displayname} &mdash; Simon Tatham's Portable Puzzle Collection</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
<link rel="stylesheet" href="puzzle-midend.css">
</head>
<body>
<header>
  <h1>${displayname}</h1>
  <span>${description}</span>
  <nav>
    ${help_link}<a href="index.html">All puzzles</a>
  </nav>
</header>
${unfinished_note}<div id="puzzle">Loading&hellip;</div>

<script type="module">
  import { mountPuzzle } from "./puzzle-midend.js";

  const el = document.getElementById("puzzle");
  mountPuzzle(el, "${name}-midend.wasm").catch((err) => {
    el.textContent = "Couldn't load ${name}-midend.wasm: " + err.message;
    console.error(err);
  });
</script>
</body>
</html>
EOF
}

my $list_items = join "", map {
    my $name = $_->{name};
    my $displayname = html_escape($_->{displayname});
    my $description = html_escape($_->{description});
    qq{  <li><a href="${name}.html">${displayname}</a><p>${description}</p></li>\n};
} grep { !$_->{unfinished} } @games;

write_file("${outdir}/index.html", <<EOF);
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Simon Tatham's Portable Puzzle Collection</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
<link rel="stylesheet" href="puzzle-midend.css">
</head>
<body>
<header>
  <h1>Simon Tatham's Portable Puzzle Collection</h1>
</header>
<main>
<ul class="puzzle-index-list">
${list_items}</ul>
</main>
</body>
</html>
EOF
