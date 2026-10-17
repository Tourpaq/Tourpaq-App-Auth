require "yaml"

# Loads the index's seed content (db/seeds/index, from Tourpaq-App-WWW's db/seeds/content: markdown cards and docs,
# site.yaml, the NetBird resource list in services.yml) into an EMPTY index, as WWW's ContentImport did (SPECS.md
# §24.3). db/seeds.rb calls it on every start; once there is content (an Index::Site row) it does nothing, so edits made
# on the admin host are never overwritten. Production gets WWW's live content through auth:import_index instead.
#
#   Index::SeedContent.load_if_empty(Rails.root.join("db/seeds/index"))
#
# Differences from WWW: sections carry a layout and the auth groups that see them (site.yaml `groups:`; a group that
# does not exist is left out and logged), and a card's `app:` ties the entry to that auth App (by slug).
class Index::SeedContent
  FRONTMATTER = /\A---\s*\n(.*?)\n---\s*\n?(.*)\z/m

  def self.load_if_empty(root, log: $stdout)
    if Index::Site.exists?
      log.puts "Index content already present, nothing to seed."
      return false
    end
    new(root, log: log).run
    true
  end

  def initialize(root, log: $stdout)
    @root = Pathname(root)
    @log = log
  end

  def run
    ActiveRecord::Base.transaction do
      import_site
      import_entries
      import_services
      import_docs
      AuditEvent.record("index.seeded", actor: nil, data: { entries: Index::Entry.count, sections: Index::Section.count, docs: Index::Doc.count })
    end
    @log.puts "Seeded the index: #{Index::Entry.count} entries in #{Index::Section.count} sections, #{Index::Doc.count} docs."
  end

  private

  def site_config
    @site_config ||= YAML.safe_load_file(@root.join("site.yaml")) || {}
  end

  def import_site
    Index::Site.create!(site_config.slice("title", "brand", "tagline", "footer"))

    Array(site_config["categories"]).each_with_index do |entry, i|
      entry = { "name" => entry } if entry.is_a?(String)
      names = Array(entry["groups"])
      groups = names.filter_map do |name|
        Group.find_by(name: name).tap { @log.puts("  #{entry['name']}: no group #{name.inspect}, left out") unless _1 }
      end
      Index::Section.create!(name: entry["name"], layout: entry["layout"] || "cards", description: entry["description"],
                             visibility: names.any? ? "groups" : "everyone", groups: groups, position: (i + 1) * 10)
    end

    { "access_levels" => Index::AccessLevel, "login_methods" => Index::LoginMethod }.each do |key, model|
      (site_config[key] || {}).each_with_index do |(name, spec), i|
        spec = { "label" => spec } if spec.is_a?(String)
        model.create!(key: name.to_s, label: spec["label"] || name.to_s, tone: spec["tone"] || "neutral", position: (i + 1) * 10)
      end
    end
  end

  def import_entries
    Dir[@root.join("apps/*.md")].sort.each do |file|
      next if File.basename(file).start_with?("_", ".")

      meta, body = parse(file)
      entry = Index::Entry.new(
        slug: Index::Sluggable.slugify(meta["slug"] || File.basename(file, ".md")),
        name: meta["name"], description: meta["description"], url: meta["url"],
        status: meta["status"].presence || "live", owner: meta["owner"], repo: meta["repo"],
        icon: meta["icon"], position: meta["order"] || 100, body: body.strip.presence,
        section: section(meta["category"]), app: app(meta["app"], file),
        access_level: vocabulary(Index::AccessLevel, meta["access"]),
        login_method: vocabulary(Index::LoginMethod, meta["login"])
      )
      links_from(meta["links"]).each_with_index do |link, i|
        entry.links.build(link.merge(position: i))
      end
      entry.save!
    end
  end

  def import_services
    path = @root.join("services.yml")
    return unless path.exist?

    YAML.safe_load_file(path).each do |item|
      existing = Index::Entry.all.find { |entry| host(entry.url) == host_of_address(item["address"]) }
      if existing
        existing.update!(address: item["address"]) if existing.address.blank?
        @log.puts "  #{item['name']}: already listed as #{existing.name.inspect}, added its address there"
        next
      end

      Index::Entry.create!(
        name: item["name"], description: item["description"], url: item["url"],
        address: item["address"], section: section(item["category"]),
        access_level: vocabulary(Index::AccessLevel, item["access"]),
        login_method: vocabulary(Index::LoginMethod, item["login"])
      )
    end
  end

  def import_docs
    order = Array(site_config["docs_sections"])
    Dir[@root.join("docs/*/")].sort.each do |dir|
      key = File.basename(dir)
      meta = File.exist?(File.join(dir, "_section.yaml")) ? YAML.safe_load_file(File.join(dir, "_section.yaml")) || {} : {}
      position = order.index(key) ? (order.index(key) + 1) * 10 : meta["order"] || 100
      Index::DocSection.create!(key: key, title: meta["title"] || key.tr("-_", "  ").capitalize, position: position)
    end

    docs = Dir[@root.join("docs/**/*.md")].sort.reject { |f| File.basename(f).start_with?("_", ".") }
    docs.each do |file|
      meta, body = parse(file)
      section_key = Pathname(file).dirname.basename.to_s
      Index::Doc.create!(
        doc_section: Index::DocSection.find_by(key: section_key),
        slug: Index::Sluggable.slugify(meta["slug"] || File.basename(file, ".md")),
        title: meta["title"], summary: meta["summary"], position: meta["order"] || 100,
        body: rewrite_md_links(body, file)
      )
    end
  end

  def parse(file)
    match = FRONTMATTER.match(File.read(file))
    raise "#{file}: missing '---' frontmatter block" unless match

    [ YAML.safe_load(match[1]) || {}, match[2] ]
  end

  def section(name)
    name.present? ? Index::Section.find_by!(name: name) : nil
  end

  def app(slug, file)
    return nil if slug.blank?
    App.find_by(slug: slug.to_s).tap { @log.puts("  #{File.basename(file)}: no app #{slug.inspect}, not tied") unless _1 }
  end

  def vocabulary(model, value)
    value.present? ? model.find_by!(key: Index::Toned.normalise(value)) : nil
  end

  # Both shapes the markdown site accepted: a mapping of label: url, or a list of { label, url, note }.
  def links_from(raw)
    case raw
    when Hash then raw.map { |label, url| { label: label.to_s, url: url.to_s } }
    when Array then raw.map { |l| { label: l["label"], url: l["url"], note: l["note"] } }
    else []
    end
  end

  # Relative links between markdown files become site paths, e.g.
  # ../getting-started/adding-an-app.md -> /docs/getting-started/adding-an-app
  def rewrite_md_links(body, file)
    body.gsub(/\]\((?!\w+:)([^)\s]+?)\.md(#[^)]*)?\)/) do
      target = Pathname(file).dirname.join("#{$1}.md").cleanpath
      relative = target.relative_path_from(@root.join("docs")).sub_ext("")
      "](/docs/#{relative}#{$2})"
    end
  end

  def host(url)
    URI.parse(url.to_s).host&.downcase
  rescue URI::InvalidURIError
    nil
  end

  def host_of_address(address)
    address.to_s.downcase.split("/").first
  end
end
