//
// Copyright Amazon.com Inc. or its affiliates.
// All Rights Reserved.
//
// SPDX-License-Identifier: Apache-2.0
//

import Foundation
import Amplify
import AWSPluginsCore

public class AppSyncListProvider<Element: Model>: ModelListProvider {

    /// The API friendly name used to reference the API to call
    let apiName: String?

    /// The limit for each page size
    var limit: Int? = 1_000

    /// The current state of lazily loaded list
    enum LoadedState {
        /// If the list represents an association between two models, the `associatedId` will
        /// hold the information necessary to query the associated elements (e.g. comments of a post)
        ///
        /// The associatedField represents the field to which the owner of the `List` is linked to.
        /// For example, if `Post.comments` is associated with `Comment.post` the `List<Comment>`
        /// of `Post` will have a reference to the `post` field in `Comment`.
        case notLoaded(associatedId: String,
                       associatedField: String)

        /// If the list is retrieved directly, this state holds the underlying data, nextToken used to create
        /// the subsequent GraphQL request, and previous filter used to create the loaded list
        case loaded(elements: [Element],
                    nextToken: String?,
                    filter: [String: Any]?)
    }

    var loadedState: LoadedState

    // MARK: - Initializers

    convenience init(payload: AppSyncListPayload) throws {
        let listResponse = try AppSyncListResponse.initWithMetadata(type: Element.self,
                                                                       graphQLData: payload.graphQLData,
                                                                       apiName: payload.apiName)

        self.init(elements: listResponse.items,
                  nextToken: listResponse.nextToken,
                  apiName: payload.apiName,
                  limit: payload.limit,
                  filter: payload.graphQLFilter)
    }

    convenience init(listResponse: AppSyncListResponse<Element>) throws {
        self.init(elements: listResponse.items,
                  nextToken: listResponse.nextToken)
    }

    convenience init(metadata: AppSyncModelMetadata) {
        self.init(associatedId: metadata.appSyncAssociatedId,
                  associatedField: metadata.appSyncAssociatedField,
                  apiName: metadata.apiName)
    }

    // Internal initializer for testing
    init(elements: [Element],
         nextToken: String? = nil,
         apiName: String? = nil,
         limit: Int? = nil,
         filter: [String: Any]? = nil) {
        self.loadedState = .loaded(elements: elements, nextToken: nextToken, filter: filter)
        self.apiName = apiName
        self.limit = limit
    }

    // Internal initializer for testing
    init(associatedId: String, associatedField: String, apiName: String? = nil) {
        self.loadedState = .notLoaded(associatedId: associatedId,
                                      associatedField: associatedField)
        self.apiName = apiName
    }

    // MARK: APIs

    public func getState() -> ModelListProviderState<Element> {
        switch loadedState {
        case .notLoaded:
            return .notLoaded
        case .loaded(let elements, _, _):
            return .loaded(elements)
        }
    }
    
    public func load() async throws -> [Element] {
        switch loadedState {
        case .loaded(let elements, _, _):
            return elements
        case .notLoaded(let associatedId, let associatedField):
            return try await load(associatedId: associatedId, associatedField: associatedField)
        }
    }

    //// Internal `load` to perform the retrieval of the first page and storing it in memory
    func load(associatedId: String,
              associatedField: String) async throws -> [Element] {
        let predicate: QueryPredicate = field(associatedField) == associatedId
        let filter = predicate.graphQLFilter(for: Element.schema)
        let request = GraphQLRequest<JSONValue>.listQuery(responseType: JSONValue.self,
                                                          modelSchema: Element.schema,
                                                          filter: filter,
                                                          limit: limit,
                                                          apiName: apiName)
        do {
            let graphQLResponse = try await Amplify.API.query(request: request)
            switch graphQLResponse {
            case .success(let graphQLData):
                guard let listResponse = try? AppSyncListResponse.initWithMetadata(type: Element.self,
                                                                                   graphQLData: graphQLData,
                                                                                   apiName: self.apiName) else {
                    throw CoreError.listOperation("""
                                            The AppSync response return successfully, but could not decode to
                                            AWSAppSyncListResponse from: \(graphQLData)
                                            """, "", nil)
                }
                
                self.loadedState = .loaded(elements: listResponse.items,
                                           nextToken: listResponse.nextToken,
                                           filter: filter)
                return listResponse.items
            case .failure(let graphQLError):
                Amplify.API.log.error(error: graphQLError)
                throw CoreError.listOperation(
                    "The AppSync response returned successfully with GraphQL errors.",
                    "Check the underlying error for the failed GraphQL response.",
                    graphQLError)
            }
        } catch let apiError as APIError {
            Amplify.API.log.error(error: apiError)
            throw CoreError.listOperation("The AppSync request failed",
                                          "See underlying `APIError` for more details.",
                                          apiError)
        } catch {
            throw error
        }
    }
    
    public func hasNextPage() -> Bool {
        switch loadedState {
        case .loaded(_, let nextToken, _):
            return nextToken != nil
        case .notLoaded:
            return false
        }
    }
    
    public func getNextPage() async throws -> List<Element> {
        guard case .loaded(_, let nextTokenOptional, let filter) = loadedState else {
            throw CoreError.clientValidation("""
                Make sure the underlying data is loaded by calling `load(completion)`, then only call this method when
                `hasNextPage()` is true
                """, "", nil)
        }
        guard let nextToken = nextTokenOptional else {
            throw CoreError.clientValidation("There is no next page.",
                                             "Only call `getNextPage()` when `hasNextPage()` is true.",
                                             nil)
        }

        return try await getNextPage(nextToken: nextToken, filter: filter)
    }

    /// Internal `getNextPage` to retrieve the next page and return it as a new List object
    func getNextPage(nextToken: String,
                     filter: [String: Any]?) async throws -> List<Element> {
        let request = GraphQLRequest<List<Element>>.listQuery(responseType: List<Element>.self,
                                                              modelSchema: Element.schema,
                                                              filter: filter,
                                                              limit: limit,
                                                              nextToken: nextToken,
                                                              apiName: apiName)
        do {
            let graphQLResponse = try await Amplify.API.query(request: request)
            switch graphQLResponse {
            case .success(let nextPageList):
                _ = try await nextPageList.fetch()
                return nextPageList
            case .failure(let graphQLError):
                Amplify.API.log.error(error: graphQLError)
                throw CoreError.listOperation("""
                    The AppSync request was processed by the service, but the response contained GraphQL errors.
                    """, "Check the underlying error for the failed GraphQL response.", graphQLError)
            }
        } catch let apiError as APIError {
            Amplify.API.log.error(error: apiError)
            throw CoreError.listOperation("The AppSync request failed",
                                          "See underlying `APIError` for more details.",
                                          apiError)
        } catch {
            throw error
        }
    }
}
