import { CloudAdapterBase } from './CloudAdapterBase';
import { GuangyaCatalog } from './GuangyaCatalog';
export class GuangyaAdapter extends CloudAdapterBase { constructor() { super('guangya', new GuangyaCatalog()); } }
