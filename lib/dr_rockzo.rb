
def gen_document(data)
  comment_block, document = false, []
  data.split(/\r?\n/).each do |line|
    line.strip!
    comment_line = line =~ /^\/\//
    line = line.sub(/^\/\//, '').strip
    document << {:comments => [], :doc => []} if comment_line && !comment_block
    if comment_block = comment_line
      document.last[:comments] << line
    else
      document.last[:doc] << ((line.length == 0 && document.last[:doc].length > 0) ? '</p><p>' : line)
    end
  end
end

def render(document)
  output = ''
  document.each_with_index do |rows, index|
    output << "<tr id=\"section-#{index}\">"
    output << "<td class=\"docs\">"
    output << "<div class=\"pilwrap\"><a class=\"pilcrow\" href=\"#section-#{index}\">&#182;</a></div>"
    output << "<p>#{rows[:comments].join("\n")}</p>"
    output << "</td>"
    output << "<td class=\"code\">"
    output << "<p>#{rows[:doc].join("\n")}</p>"
    output << "</td>"
  end
  output
end

doc = gen_document(data)
render(doc)
