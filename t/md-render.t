#!/usr/bin/perl
# md-render.t — the chat page's small markdown subset.
# usage: perl t/md-render.t

use strict;
use warnings;
use FindBin;
$| = 1;

my $bin = "$FindBin::Bin/../bin/picobus";
open my $fh, '<', $bin or die "$bin: $!";
my $src = do { local $/; <$fh> };
close $fh;
my $start = index($src, "  function esc(s)");
my $end = index($src, "  function nearBottom");
die "renderer not found\n" if $start < 0 || $end < $start;
my $js = substr($src, $start, $end - $start);

my $node = <<'END';
var cases = [
  ["hello <script>", "<p>hello &lt;script&gt;</p>"],
  ["**bold**", "<p><strong>bold</strong></p>"],
  ["*italic*", "<p><em>italic</em></p>"],
  ["`**x**`", "<p><code>**x**</code></p>"],
  ["**no", "<p>**no</p>"],
  ["a\nb", "<p>a<br>b</p>"],
  ["a\n\nb", "<p>a</p><p>b</p>"],
  ["- a\n- b", "<ul><li>a</li><li>b</li></ul>"],
  ["* a\n* b", "<ul><li>a</li><li>b</li></ul>"],
  ["1. a\n2. b", "<ol><li>a</li><li>b</li></ol>"],
  ["2. two\n3. three", "<ol start=\"2\"><li>two</li><li>three</li></ol>"],
  ["## Title", "<h2>Title</h2>"],
  ["#nope", "<p>#nope</p>"],
  ["see *this* and **that**", "<p>see <em>this</em> and <strong>that</strong></p>"],
  ["a\n\n- b", "<p>a</p><ul><li>b</li></ul>"],
  ["`<b>`", "<p><code>&lt;b&gt;</code></p>"],
  ["- **a**", "<ul><li><strong>a</strong></li></ul>"],
  ["</p><img src=x>", "<p>&lt;/p&gt;&lt;img src=x&gt;</p>"],
  ["a\n   \nb", "<p>a</p><p>b</p>"],
  ["say `a` please", "<p>say <code>a</code> please</p>"],
  ["```\n<b>\n```", "<pre><code>&lt;b&gt;</code></pre>"],
  ["```\n**x**\n```", "<pre><code>**x**</code></pre>"],
  ["```js\nvar a = 1;\n```", "<pre><code class=\"language-js\">var a = 1;</code></pre>"],
  ["```\n  indent\n```", "<pre><code>  indent</code></pre>"],
  ["```\nline1\n\nline2\n```", "<pre><code>line1\n\nline2</code></pre>"],
  ["```\nno close", "<pre><code>no close</code></pre>"],
  ["say\n```\ncode\n```\nmore", "<p>say</p><pre><code>code</code></pre><p>more</p>"],
  ["```\"><b>\nx\n```", "<pre><code>x</code></pre>"],
  ["```\r\na\r\n```", "<pre><code>a</code></pre>"],
  ["| a | b |\n| --- | --- |\n| 1 | 2 |", "<div class=\"md-table\"><table><thead><tr><th>a</th><th>b</th></tr></thead><tbody><tr><td>1</td><td>2</td></tr></tbody></table></div>"],
  ["a | b\n--- | ---\n**1** | 2", "<div class=\"md-table\"><table><thead><tr><th>a</th><th>b</th></tr></thead><tbody><tr><td><strong>1</strong></td><td>2</td></tr></tbody></table></div>"],
  ["| a | b |\n| ---: | :---: |\n| 1 | 2 |", "<div class=\"md-table\"><table><thead><tr><th class=\"r\">a</th><th class=\"c\">b</th></tr></thead><tbody><tr><td class=\"r\">1</td><td class=\"c\">2</td></tr></tbody></table></div>"],
  ["| <b> |\n| --- |\n| x |", "<div class=\"md-table\"><table><thead><tr><th>&lt;b&gt;</th></tr></thead><tbody><tr><td>x</td></tr></tbody></table></div>"],
  ["| `a|b` | c |\n| --- | --- |\n| 1 | 2 |", "<div class=\"md-table\"><table><thead><tr><th><code>a|b</code></th><th>c</th></tr></thead><tbody><tr><td>1</td><td>2</td></tr></tbody></table></div>"],
  ["not | a table", "<p>not | a table</p>"],
  ["| a |\n| --- |\n| 1 |\n\nafter", "<div class=\"md-table\"><table><thead><tr><th>a</th></tr></thead><tbody><tr><td>1</td></tr></tbody></table></div><p>after</p>"],
  ["<table><tr><td>a</td></tr></table>", "<p>&lt;table&gt;&lt;tr&gt;&lt;td&gt;a&lt;/td&gt;&lt;/tr&gt;&lt;/table&gt;</p>"]
];
var fail = 0;
for (var i = 0; i < cases.length; i++) {
  var got = renderMd(cases[i][0]);
  if (got === cases[i][1]) process.stdout.write("ok - " + i + "\n");
  else {
    fail++;
    process.stdout.write("NOT OK - " + i + "\n got " + got + "\n want " + cases[i][1] + "\n");
  }
}
var nul = renderMd("\u00001\u0000");
if (nul === "<p>1</p>" && nul.indexOf("<code>") < 0) process.stdout.write("ok - nulls are not code\n");
else { fail++; process.stdout.write("NOT OK - nulls\n got " + nul + "\n"); }
if (fail) process.exit(1);
END

my $prog = $js . "\n" . $node;
open my $out, '-|', 'node', '-e', $prog or die "node: $!";
my ($pass, $fail) = (0, 0);
while (my $line = <$out>) {
    print $line;
    $pass++ if $line =~ /^ok /;
    $fail++ if $line =~ /^NOT OK /;
}
close $out;
my $rc = $? >> 8;
$fail++ if $rc && !$fail;
print $fail ? "FAIL $fail  pass $pass\n" : "PASS $pass\n";
exit($fail ? 1 : 0);
