import { http } from '@kit.NetworkKit';

/**
 * TMDB 客户端 —— 用于 Vision（发现页）
 *
 * 需要用户在「TMDB设置」里填 API Key（免费申请：themoviedb.org/settings/api）
 * 图片走 https://image.tmdb.org/t/p/w342{poster_path}
 */

/** TMDB 条目 */
export class TmdbItem {
  id: number = 0;
  title: string = '';
  originalTitle: string = '';
  overview: string = '';
  posterPath: string = '';
  backdropPath: string = '';
  mediaType: string = '';      // movie / tv
  voteAverage: number = 0;
  releaseDate: string = '';
  genreIds: number[] = [];
}

interface RawTmdbItem {
  id?: number;
  title?: string;
  name?: string;
  original_title?: string;
  original_name?: string;
  overview?: string;
  poster_path?: string;
  backdrop_path?: string;
  media_type?: string;
  vote_average?: number;
  release_date?: string;
  first_air_date?: string;
  genre_ids?: number[];
}

interface RawTmdbResp {
  page?: number;
  results?: RawTmdbItem[];
  total_pages?: number;
  total_results?: number;
  status_code?: number;
  status_message?: string;
}

export class TmdbClient {
  private static readonly BASE: string = 'https://api.themoviedb.org/3';
  private static readonly IMG: string = 'https://image.tmdb.org/t/p';

  private static async get(key: string, path: string, lang: string): Promise<string> {
    const req = http.createHttp();
    try {
      const url = TmdbClient.BASE + path +
        (path.indexOf('?') >= 0 ? '&' : '?') +
        'api_key=' + key + '&language=' + lang;
      const resp = await req.request(url, {
        method: http.RequestMethod.GET,
        header: {
          'Accept': 'application/json'
        } as Record<string, string>,
        connectTimeout: 12000,
        readTimeout: 20000,
        expectDataType: http.HttpDataType.STRING
      });
      const code = resp.responseCode as number;
      const body = resp.result as string;
      if (code < 200 || code >= 300) {
        throw new Error('TMDB HTTP ' + code.toString());
      }
      return body;
    } finally {
      req.destroy();
    }
  }

  /** 通用列表拉取 */
  static async list(key: string, path: string, lang: string): Promise<TmdbItem[]> {
    if (key.length === 0) {
      return [];
    }
    try {
      const raw = await TmdbClient.get(key, path, lang);
      const d = JSON.parse(raw) as RawTmdbResp;
      if (d.status_code !== undefined && d.status_code !== 0) {
        throw new Error(d.status_message !== undefined ? d.status_message : 'TMDB 错误');
      }
      const arr: RawTmdbItem[] = d.results !== undefined ? d.results : [];
      const out: TmdbItem[] = [];
      for (let i = 0; i < arr.length; i++) {
        const r = arr[i];
        const it = new TmdbItem();
        it.id = r.id !== undefined ? r.id : 0;
        it.title = r.title !== undefined ? r.title :
          (r.name !== undefined ? r.name : '');
        it.originalTitle = r.original_title !== undefined ? r.original_title :
          (r.original_name !== undefined ? r.original_name : '');
        it.overview = r.overview !== undefined ? r.overview : '';
        it.posterPath = r.poster_path !== undefined ? r.poster_path : '';
        it.backdropPath = r.backdrop_path !== undefined ? r.backdrop_path : '';
        it.mediaType = r.media_type !== undefined ? r.media_type : '';
        it.voteAverage = r.vote_average !== undefined ? r.vote_average : 0;
        it.releaseDate = r.release_date !== undefined ? r.release_date :
          (r.first_air_date !== undefined ? r.first_air_date : '');
        it.genreIds = r.genre_ids !== undefined ? r.genre_ids : [];
        out.push(it);
      }
      return out;
    } catch (e) {
      return [];
    }
  }

  /** 本周趋势 */
  static async trending(key: string, lang: string): Promise<TmdbItem[]> {
    return TmdbClient.list(key, '/trending/all/week', lang);
  }

  /** 热门电影 */
  static async popularMovies(key: string, lang: string): Promise<TmdbItem[]> {
    return TmdbClient.list(key, '/movie/popular', lang);
  }

  /** 高分电影 */
  static async topRatedMovies(key: string, lang: string): Promise<TmdbItem[]> {
    return TmdbClient.list(key, '/movie/top_rated', lang);
  }

  /** 热门剧集 */
  static async popularTv(key: string, lang: string): Promise<TmdbItem[]> {
    return TmdbClient.list(key, '/tv/popular', lang);
  }

  /** 正在上映 */
  static async nowPlaying(key: string, lang: string): Promise<TmdbItem[]> {
    return TmdbClient.list(key, '/movie/now_playing', lang);
  }

  /** 即将上映（订阅用） */
  static async upcoming(key: string, lang: string): Promise<TmdbItem[]> {
    return TmdbClient.list(key, '/movie/upcoming', lang);
  }

  /** 正在播出的剧 */
  static async onTheAir(key: string, lang: string): Promise<TmdbItem[]> {
    return TmdbClient.list(key, '/tv/on_the_air', lang);
  }

  /** 搜索 */
  static async search(key: string, q: string, lang: string): Promise<TmdbItem[]> {
    const enc = encodeURIComponent(q);
    return TmdbClient.list(key, '/search/multi?query=' + enc, lang);
  }

  /** 海报 URL */
  static posterUrl(path: string, w: number): string {
    if (path.length === 0) {
      return '';
    }
    return TmdbClient.IMG + '/w' + w.toString() + path;
  }

  /** 背景图 URL */
  static backdropUrl(path: string, w: number): string {
    if (path.length === 0) {
      return '';
    }
    return TmdbClient.IMG + '/w' + w.toString() + path;
  }

  /** 校验 key 是否有效 */
  static async validate(key: string): Promise<boolean> {
    if (key.length < 8) {
      return false;
    }
    const r = await TmdbClient.trending(key, 'zh-CN');
    return r.length > 0;
  }
}
