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
package com.google.dart.engine;

import com.google.dart.engine.source.SourceFactory;
import com.google.dart.engine.utilities.logging.Logger;

/**
 * The unique instance of the class {@code AnalysisEngine} serves as the entry point for the
 * functionality provided by the analysis engine.
 */
public final class AnalysisEngine {
  /**
   * The unique instance of this class.
   */
  private static final AnalysisEngine UniqueInstance = new AnalysisEngine();

  /**
   * Return the unique instance of this class.
   * 
   * @return the unique instance of this class
   */
  public static AnalysisEngine getInstance() {
    return UniqueInstance;
  }

  /**
   * The logger that should receive information about errors within the analysis engine.
   */
  private Logger logger = Logger.NULL;

  /**
   * The source factory used to create source objects.
   */
  private SourceFactory sourceFactory;

  /**
   * Prevent the creation of instances of this class.
   */
  private AnalysisEngine() {
    super();
  }

  /**
   * Return the logger that should receive information about errors within the analysis engine.
   * 
   * @return the logger that should receive information about errors within the analysis engine
   */
  public Logger getLogger() {
    return logger;
  }

  /**
   * Return the source factory used to create source objects, or {@code null} if the source factory
   * has not been configured.
   * 
   * @return the source factory used to create source objects
   */
  public SourceFactory getSourceFactory() {
    return sourceFactory;
  }

  /**
   * Set the logger that should receive information about errors within the analysis engine to the
   * given logger.
   * 
   * @param logger the logger that should receive information about errors within the analysis
   *          engine
   */
  public void setLogger(Logger logger) {
    this.logger = logger == null ? Logger.NULL : logger;
  }

  /**
   * Set the source factory used to create source objects to the given factory.
   * 
   * @param factory the source factory that is to be used to create source objects
   */
  public void setSourceFactory(SourceFactory factory) {
    sourceFactory = factory;
  }
}
