require "test_helper"

# The index's markdown (WWW's Markdown.render): GFM, highlighted, anchored, and sanitised.
class Index::MarkdownTest < ActiveSupport::TestCase
  test "renders GFM with heading anchors and a toc of h2 and h3" do
    result = Index::Markdown.render("## Before you start\n\ntext\n\n### Detail\n\n| a | b |\n|---|---|\n| 1 | 2 |")
    assert_includes result.html, %(<h2 id="before-you-start">)
    assert_includes result.html, %(class="headerlink" href="#before-you-start")
    assert_includes result.html, "<table>"
    assert_equal [ "before-you-start", "detail" ], result.toc.map { |t| t[:id] }
    assert_equal [ 2, 3 ], result.toc.map { |t| t[:level] }
  end

  test "highlights fenced code" do
    assert_includes Index::Markdown.render("```ruby\nputs 1\n```").html, "highlight"
  end

  test "strips anything that could run script" do
    html = Index::Markdown.render(%(hi <script>alert(1)</script> <img src=x onerror="alert(1)"> [x](javascript:alert(1)) <a href="data:text/html,x">d</a> <iframe src="https://x"></iframe> <p style="color:red">s</p>)).html
    assert_not_includes html, "<script"
    assert_not_includes html, "onerror"
    assert_not_includes html, "javascript:"
    assert_not_includes html, "data:text"
    assert_not_includes html, "<iframe"
    fragment = Nokogiri::HTML5.fragment(html)
    assert_empty fragment.css("[style], [onerror], script, iframe")
  end

  test "external links don't send a referrer" do
    assert_includes Index::Markdown.render("[g](https://grafana.tourpaq.com)").html, %(rel="noreferrer")
  end

  test "blank is empty" do
    assert_equal "", Index::Markdown.render(nil).html
  end
end
