/// Remote catalogue contract.
///
/// Kept as an interface so the app can run with no network layer at all
/// (bundled assets only), and so tests can supply a fake without HTTP.
library;

import '../../../core/error/result.dart';
import '../../../domain/repositories/asset_library_repository.dart';

abstract interface class AssetCatalogApi {
  Future<Result<List<LibraryItem>>> fetchCatalog(LibraryCategory category);

  Future<Result<void>> download(
    String url,
    String targetPath, {
    void Function(double progress)? onProgress,
  });
}
