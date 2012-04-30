/*
 * Copyright (c) 2012, the Dart project authors.
 * 
 * Licensed under the Eclipse Public License v1.0 (the "License"); you may not use this file except
 * in compliance with the License. You may obtain a copy of the License at
 * 
 * http://www.eclipse.org/legal/epl-v10.html
 * 
 * Unless required by applicable law or agreed to in writing, software distributed under the License
 * is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express
 * or implied. See the License for the specific language governing permissions and limitations under
 * the License.
 */
package com.google.dart.engine.source;

import java.io.File;
import java.net.URI;

/**
 * Instances of the class <code>FileUriResolver</code> resolve <code>file</code> URI's.
 */
public class FileUriResolver extends UriResolver {
  /**
   * The name of the <code>file</code> scheme.
   */
  private static final String FILE_SCHEME = "file";

  /**
   * Return <code>true</code> if the given URI is a <code>file</code> URI.
   * 
   * @param uri the URI being tested
   * @return <code>true</code> if the given URI is a <code>file</code> URI
   */
  public static boolean isFileUri(URI uri) {
    return uri.getScheme().equals(FILE_SCHEME);
  }

  /**
   * Initialize a newly created resolver to resolve <code>file</code> URI's relative to the given
   * root directory.
   */
  public FileUriResolver() {
    super();
  }

  @Override
  protected Source resolveAbsolute(SourceFactory factory, URI uri) {
    if (!isFileUri(uri)) {
      return null;
    }
    return new SourceImpl(factory, new File(uri));
  }
}
