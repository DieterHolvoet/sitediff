# frozen_string_literal: true

require 'sitediff'
require 'sitediff/exception'
require 'sitediff/sanitize/dom_transform'
require 'sitediff/sanitize/regexp'
require 'nokogiri'
require 'set'

class SiteDiff
  # SiteDiff Sanitizer.
  class Sanitizer
    class InvalidSanitization < SiteDiffException; end

    TOOLS = {
      array: %w[dom_transform sanitization],
      scalar: %w[selector remove_spacing ignore_whitespace]
    }.freeze
    DOM_TRANSFORMS = Set.new(%w[remove strip unwrap_root unwrap remove_class])

    ##
    # Creates a Sanitizer.
    def initialize(html, config, opts = {})
      @html = html
      @config = config
      @opts = opts
    end

    ##
    # Performs sanitization.
    def sanitize
      return '' if @html == '' # Quick return on empty input

      @node = Sanitizer.domify(@html)
      @html = nil

      remove_spacing
      regions || selector
      dom_transforms
      regexps

      @html || Sanitizer.prettify(@node)
    end

    # Return whether or not we want to keep a rule
    def want_rule(rule)
      return false unless rule
      return false if rule['disabled']

      # Filter out if path regexp doesn't match
      if (pathre = rule['path']) && (path = @opts[:path])
        return ::Regexp.new(pathre).match(path)
      end

      true
    end

    # Canonicalize a simple rule, eg: 'remove_spacing' or 'selector'.
    # It may be a simple value, or a hash, or an array of hashes.
    # Turn it into an array of hashes.
    def canonicalize_rule(name)
      (rules = @config[name]) || (return nil)

      # Already an array? Do nothing.
      if rules[0].respond_to?('each') && rules[0]&.fetch('value')
      # If it is a hash, put it in an array.
      elsif rules['value']
        rules = [rules]
      # If it is a scalar value, put it in an array.
      else
        rules = [{ 'value' => rules }]
      end

      want = rules.select { |r| want_rule(r) }
      return nil if want.empty?
      raise "Too many matching rules of type #{name}" if want.size > 1

      want.first
    end

    # Perform 'remove_spacing' action
    def remove_spacing
      (rule = canonicalize_rule('remove_spacing')) || return
      Sanitizer.remove_node_spacing(@node) if rule['value']
    end

    # Perform 'regions' action, don't perform 'selector' if regions exist.
    def regions
      return unless validate_regions

      @node = select_regions(@node, @config['regions'], @opts[:output])
    end

    # Perform 'selector' action, to choose a new root
    def selector
      (rule = canonicalize_rule('selector')) || return
      @node = Sanitizer.select_fragments(@node, rule['value'])
    end

    # Applies regexps. Also
    def regexps
      (rules = @config['sanitization']) || return
      rules = rules.select { |r| want_rule(r) }

      rules.map! { |r| Regexp.create(r) }
      selector, global = rules.partition(&:selector?)

      selector.each { |r| r.apply(@node) }
      @html = Sanitizer.prettify(@node)
      @node = nil
      # Prevent potential UTF-8 encoding errors by removing bytes
      # Not the only solution. An alternative is to return the
      # string unmodified.
      @html = @html.encode(
        'UTF-8',
        'binary',
        invalid: :replace,
        undef: :replace,
        replace: ''
      )
      global.each { |r| r.apply(@html) }
    end

    # Perform DOM transforms
    def dom_transforms
      (rules = @config['dom_transform']) || return
      rules = rules.select { |r| want_rule(r) }

      rules.each do |rule|
        transform = DomTransform.create(rule)
        transform.apply(@node)
      end
    end

    ##### Implementations of actions #####

    # Remove double-spacing inside text nodes
    def self.remove_node_spacing(node)
      # remove double spacing, but only inside text nodes (eg not attributes)
      node.xpath('//text()').each do |el|
        el.content = el.content.gsub(/  +/, ' ')
      end
    end

    # Restructure the node into regions.
    def select_regions(node, regions, output)
      regions = output.map do |name|
        selector = get_named_region(regions, name)['selector']
        region = Nokogiri::XML.fragment("<region id=\"#{name}\"></region>").at_css('region')
        matching = node.css(selector)
        matching.each { |m| region.add_child m }
        region
      end
      node = Nokogiri::HTML.fragment('')
      regions.each { |r| node.add_child r }
      node
    end

    # Get a fragment consisting of the elements matching the selector(s)
    def self.select_fragments(node, sel)
      # When we choose a new root, we always become a DocumentFragment,
      # and lose any DOCTYPE and such.
      ns = node.css(sel)
      node = Nokogiri::HTML.fragment('') unless node.fragment?
      node.children = ns
      node
    end

    # Pretty-print some HTML
    def self.prettify(obj)
      @stylesheet ||= begin
        stylesheet_path = File.join(SiteDiff::FILES_DIR, 'pretty_print.xsl')
        Nokogiri::XSLT(File.read(stylesheet_path))
      end

      # Pull out the html element's children
      # The obvious way to do this is to iterate over pretty.css('html'),
      # but that tends to segfault Nokogiri
      str = @stylesheet.apply_to(to_document(obj))

      # There's a lot of cruft left over,that we don't want

      # Prevent potential UTF-8 encoding errors by removing invalid bytes.
      # Not the only solution.
      # An alternative is to return the string unmodified.
      str = str.encode(
        'UTF-8',
        'binary',
        invalid: :replace,
        undef: :replace,
        replace: ''
      )
      # Remove xml declaration and <html> tags
      str.sub!(/\A<\?xml.*$\n/, '')
      str.sub!(/\A^<html>$\n/, '')
      str.sub!(%r{</html>\n\Z}, '')

      # Remove top-level indentation
      indent = /\A(\s*)/.match(str)[1].size
      str.gsub!(/^\s{,#{indent}}/, '')

      # Remove blank lines
      str.gsub!(/^\s*$\n/, '')

      # Remove DOS newlines
      str.gsub!(/\x0D$/, '')
      str.gsub!(/&#13;$/, '')

      str
    end

    # Parse HTML into a node
    def self.domify(str, force_doc: false)
      if force_doc || /<!DOCTYPE/.match(str[0, 512])
        Nokogiri::HTML(str)
      else
        Nokogiri::HTML.fragment(str)
      end
    end

    # Force this object to be a document, so we can apply a stylesheet
    def self.to_document(obj)
      if Nokogiri::XML::Document == obj.class || Nokogiri::HTML::Document == obj.class
        obj
      # node or fragment
      elsif Nokogiri::XML::Node == obj.class || Nokogiri::HTML::DocumentFragment == obj.class
        domify(obj.to_s, force_doc: true)
      else
        to_document(domify(obj, force_doc: false))
      end
    end

    private

    # Validate `regions` and `output` from config.
    def validate_regions
      return false unless @config['regions'].is_a?(Array)

      return false unless @opts[:output].is_a?(Array)

      regions = @config['regions']
      output = @opts[:output]
      regions.each do |region|
        return false unless region.key?('name') && region.key?('selector')
      end

      # Check that each named output has an associated region.
      output.each do |name|
        return false unless get_named_region(regions, name)
      end

      true
    end

    # Return the selector from a named region.
    def get_named_region(regions, name)
      regions.find { |region| region['name'] == name }
    end
  end
end
