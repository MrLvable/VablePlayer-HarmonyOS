export class SourceXmlNode {
  name: string = '';
  local: string = '';
  namespace: string = '';
  attributes: Record<string, string> = {};
  namespaces: Record<string, string> = {};
  children: SourceXmlNode[] = [];
  text: string = '';
  value(): string { return this.text + this.children.map((node: SourceXmlNode) => node.value()).join(''); }
  all(local: string, namespace: string = ''): SourceXmlNode[] {
    return this.children.filter((node: SourceXmlNode) => node.local === local && node.namespace === namespace);
  }
  first(local: string, namespace: string = ''): SourceXmlNode | undefined { return this.all(local, namespace)[0]; }
  field(local: string, namespace: string = ''): string { const node = this.first(local, namespace); return node === undefined ? '' : node.value().trim(); }
}

/** Bounded XML subset for DAV/XMLTV. Never loads DTDs or resolves external entities. */
export class SourceXml {
  static decode(text: string): string {
    return text.replace(/&([^;]+);/g, (_whole: string, entity: string): string => {
      if (entity === 'amp') { return '&'; } if (entity === 'lt') { return '<'; }
      if (entity === 'gt') { return '>'; } if (entity === 'quot') { return '"'; } if (entity === 'apos') { return "'"; }
      if (/^#(?:[0-9]+|x[0-9a-f]+)$/i.test(entity)) {
        const value = entity.charAt(1).toLowerCase() === 'x' ? parseInt(entity.substring(2), 16) : parseInt(entity.substring(1), 10);
        if (value > 0 && value <= 0x10ffff && !(value >= 0xd800 && value <= 0xdfff)) { return String.fromCodePoint(value); }
      }
      throw new Error('XML 包含不支持的实体');
    });
  }
  static parse(raw: string): SourceXmlNode {
    if (raw.length === 0 || raw.length > 8388608 || /<!ENTITY/i.test(raw) || /<!DOCTYPE[^>]*\[/i.test(raw)) {
      throw new Error('XML 文档为空、过大或包含不支持的实体声明');
    }
    const wrapper = new SourceXmlNode();
    const stack: SourceXmlNode[] = [wrapper];
    let pos = 0; let nodes = 0;
    while (pos < raw.length) {
      const open = raw.indexOf('<', pos);
      if (open < 0) { stack[stack.length - 1].text += SourceXml.decode(raw.substring(pos)); break; }
      stack[stack.length - 1].text += SourceXml.decode(raw.substring(pos, open));
      if (raw.startsWith('<!--', open)) {
        const end = raw.indexOf('-->', open + 4); if (end < 0) { throw new Error('XML 注释不完整'); } pos = end + 3; continue;
      }
      if (raw.startsWith('<![CDATA[', open)) {
        const end = raw.indexOf(']]>', open + 9); if (end < 0) { throw new Error('XML 文本不完整'); }
        stack[stack.length - 1].text += raw.substring(open + 9, end); pos = end + 3; continue;
      }
      let quote = ''; let end = open + 1;
      for (; end < raw.length; end++) {
        const char = raw.charAt(end);
        if (quote.length > 0) { if (char === quote) { quote = ''; } }
        else if (char === '"' || char === "'") { quote = char; }
        else if (char === '>') { break; }
      }
      if (end >= raw.length) { throw new Error('XML 标签不完整'); }
      const tag = raw.substring(open + 1, end).trim(); pos = end + 1;
      if (tag.startsWith('?') || /^!DOCTYPE\b/i.test(tag)) { continue; }
      if (tag.startsWith('!')) { throw new Error('不支持的 XML 声明'); }
      if (tag.startsWith('/')) {
        if (stack.length < 2 || stack[stack.length - 1].name !== tag.substring(1).trim()) { throw new Error('XML 标签不匹配'); }
        stack.pop(); continue;
      }
      const match = /^([A-Za-z_][\w:.-]*)/.exec(tag);
      if (match === null || ++nodes > 50000 || stack.length > 32) { throw new Error('XML 结构无效或超过限制'); }
      const node = new SourceXmlNode(); node.name = match[1];
      const parent = stack[stack.length - 1];
      Object.keys(parent.namespaces).forEach((key: string) => { node.namespaces[key] = parent.namespaces[key]; });
      let rest = tag.substring(match[0].length).replace(/\/$/, '').trim();
      while (rest.length > 0) {
        const attribute = /^([A-Za-z_][\w:.-]*)\s*=\s*(["'])([\s\S]*?)\2\s*/.exec(rest);
        if (attribute === null || node.attributes[attribute[1]] !== undefined) { throw new Error('XML 属性无效'); }
        const value = SourceXml.decode(attribute[3]); node.attributes[attribute[1]] = value;
        if (attribute[1] === 'xmlns') { node.namespaces[''] = value; }
        else if (attribute[1].startsWith('xmlns:')) { node.namespaces[attribute[1].substring(6)] = value; }
        rest = rest.substring(attribute[0].length);
      }
      const colon = node.name.indexOf(':'); const prefix = colon >= 0 ? node.name.substring(0, colon) : '';
      node.local = colon >= 0 ? node.name.substring(colon + 1) : node.name;
      node.namespace = node.namespaces[prefix] !== undefined ? node.namespaces[prefix] : '';
      if (prefix.length > 0 && node.namespace.length === 0) { throw new Error('XML 命名空间未声明'); }
      parent.children.push(node);
      if (!tag.endsWith('/')) { stack.push(node); }
    }
    if (stack.length !== 1 || wrapper.children.length !== 1 || wrapper.text.trim().length > 0) { throw new Error('XML 根结构无效'); }
    return wrapper.children[0];
  }
}
