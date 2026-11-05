import { CloudAdapterBase } from './CloudAdapterBase';
import { CloudDriveCatalog } from './CloudDriveCatalog';
export class CloudDriveAdapter extends CloudAdapterBase { constructor() { super('clouddrive', new CloudDriveCatalog()); } }
