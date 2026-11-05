import { CloudAdapterBase } from './CloudAdapterBase';
import { BaiduCatalog } from './BaiduCatalog';
export class BaiduAdapter extends CloudAdapterBase { constructor() { super('baidu', new BaiduCatalog()); } }
