# One RFC 4180 CSV line (CRLF), without the csv gem (a bundled gem since Ruby 3.4, not in the
# Gemfile). Cells that a spreadsheet would read as a formula (=, +, -, @, tab, CR) get a leading
# apostrophe, so an exported name like "=HYPERLINK(…)" stays text.
module CsvLine
  FORMULA_START = /\A[=+\-@\t\r]/

  module_function

  def call(values) = values.map { cell(_1) }.join(",") + "\r\n"

  def cell(value)
    text = value.to_s
    text = "'#{text}" if text.match?(FORMULA_START)
    text.match?(/[",\r\n]/) ? "\"#{text.gsub('"', '""')}\"" : text
  end
end
